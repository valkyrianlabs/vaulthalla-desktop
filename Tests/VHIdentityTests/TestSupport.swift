import CryptoKit
import Foundation
import Security
import Testing
import VHIdentity

/// Keychain hygiene for tests. Every store gets a namespace unique to the run
/// (`sh.vaulthalla.desktop.test.<uuid>`), so a test can only ever find, and delete, items it created. Nothing here
/// enumerates or prints other Keychain items.
enum TestKeychain {
    /// Node tags tests may use; cleanup deletes all of them.
    static let nodeTags = ["node-a", "node-b", "server", "client", "stranger"]

    static func namespace() -> String { "sh.vaulthalla.desktop.test.\(UUID().uuidString.lowercased())" }

    /// Runs `body` with a file-keychain store (the data protection keychain needs entitlements `swift test` lacks)
    /// and deletes everything under its namespace afterwards, also when `body` throws.
    @discardableResult
    static func withStore<R: Sendable>(
        keychain: DeviceIdentityStore.Keychain = .fileBased,
        _ body: (DeviceIdentityStore) async throws -> R
    ) async throws -> R {
        // The file keychain fails key generation and identity matching under concurrent writers
        // ("failed to generate CDSA key"), and Swift Testing runs suites in parallel: one store at a time.
        await KeychainLock.shared.acquire()
        let store = DeviceIdentityStore(configuration: .init(namespace: namespace(), keychain: keychain))
        do {
            let result = try await body(store)
            try await cleanUp(store)
            await KeychainLock.shared.release()
            return result
        } catch {
            try? await cleanUp(store)
            await KeychainLock.shared.release()
            throw error
        }
    }

    static func cleanUp(_ store: DeviceIdentityStore) async throws {
        for tag in nodeTags {
            do {
                try await store.deleteIdentity(for: tag)
            } catch IdentityError.missingEntitlement {
                return  // nothing could have been created
            }
        }
    }

    /// True when this process may use the data protection keychain. Reads there succeed (finding nothing) even
    /// without entitlements, so this probes with a delete of a random, never-written tag: it can't match anything,
    /// and an unsigned test runner gets `errSecMissingEntitlement`.
    static var dataProtectionKeychainAvailable: Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(namespace().utf8),
            kSecUseDataProtectionKeychain: true,
        ]
        return SecItemDelete(query as CFDictionary) != errSecMissingEntitlement
    }

    /// True if the Keychain still holds a private key with `tag` or a certificate whose public-key hash is `hash`.
    /// Both filters are honored by both keychains (`KeychainQueries`).
    static func hasLeftovers(
        applicationTag tag: String, publicKeyHash hash: Data, keychain: DeviceIdentityStore.Keychain = .fileBased
    ) -> Bool {
        var key: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrApplicationTag: Data(tag.utf8)]
        var certificate: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: hash]
        if keychain == .dataProtection {
            key[kSecUseDataProtectionKeychain] = true
            certificate[kSecUseDataProtectionKeychain] = true
        }
        return SecItemCopyMatching(key as CFDictionary, nil) != errSecItemNotFound
            || SecItemCopyMatching(certificate as CFDictionary, nil) != errSecItemNotFound
    }
}

/// A FIFO async mutex serializing the tests that write to the Keychain. Other test targets run in the same process
/// (VHNodesTests writes keys too), so the holder also takes a lock file shared by every target that writes keys.
actor KeychainLock {
    static let shared = KeychainLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let file = open(
        FileManager.default.temporaryDirectory.appending(path: "sh.vaulthalla.desktop.test.keychain.lock").path,
        O_CREAT | O_RDWR, 0o600)

    func acquire() async {
        if held {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            held = true
        }
        // Non-blocking with a short sleep, so waiting never parks a cooperative thread.
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        flock(file, LOCK_UN)
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

/// An ephemeral (never stored) software P-256 key.
func ephemeralKey() throws -> SecKey {
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits: 256,
        kSecAttrIsPermanent: false,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
        throw TestFailure("ephemeral key generation failed")
    }
    return key
}

/// Imports an uncompressed P-256 point as a public `SecKey`.
func publicKey(x963 point: Data) throws -> SecKey {
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass: kSecAttrKeyClassPublic,
    ]
    guard let key = SecKeyCreateWithData(point as CFData, attributes as CFDictionary, nil) else {
        throw TestFailure("public key import failed")
    }
    return key
}

/// SHA-1 of the uncompressed public point: the Keychain's `kSecAttrPublicKeyHash` for an EC certificate.
func publicKeyHash(_ key: SecKey) throws -> Data {
    let publicKey = try #require(SecKeyCopyPublicKey(key))
    let point = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
    return Data(Insecure.SHA1.hash(data: point))
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// `count` bytes counting up from `start` (the test-vector convention in docs/pairing.md).
    static func counting(from start: UInt8, count: Int = 32) -> Data {
        Data((0..<count).map { start &+ UInt8($0) })
    }
}

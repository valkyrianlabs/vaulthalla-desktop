public import CryptoKit
public import Foundation
import LocalAuthentication
import Security
public import VHKeykit

/// The key this Mac holds the account key with (docs/cloud-storage.md, "Keeping it"): a P-256 key-agreement key, the
/// account key kept as KAK1 sealed to it. CryptoKit does only this key's agreement, inside vl-keykit's callback.
public protocol HolderKey: Sendable {
    var kind: HolderKeyKind { get }
    /// The 65-byte uncompressed point, as `POST /v1/keys/holders` and KAK1 name it.
    var publicKey: Data { get }
    /// What to keep to use the key again: a Secure Enclave key's opaque data representation (useless off this
    /// Mac's enclave), or a software key's scalar.
    var storedRepresentation: Data { get }
    /// Z with `ephemeral` (the 65-byte point), written into `z` (32 bytes). May ask for Touch ID or the password.
    func agree(_ ephemeral: Data, into z: UnsafeMutableRawBufferPointer) throws
}

public enum HolderKeyKind: String, Codable, Sendable, Hashable {
    /// In the Secure Enclave, every use asking for Touch ID or the Mac's password (open question 1).
    case secureEnclave
    /// In software, where there is no Secure Enclave: the scalar is a keychain item of the app-only group.
    case software
}

public enum HolderKeyError: Error, Sendable, Equatable {
    case unusable(String)
}

/// A Secure Enclave P-256 key. `userPresence` makes every agreement ask for Touch ID or the password.
public struct EnclaveHolderKey: HolderKey {
    public let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    public var kind: HolderKeyKind { .secureEnclave }
    public var publicKey: Data { key.publicKey.x963Representation }
    public var storedRepresentation: Data { key.dataRepresentation }

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// A new key. With `userPresence`, the enclave asks for Touch ID or the password on each use.
    /// Without `userPresence` the key takes CryptoKit's default access (this device, while unlocked): that is what an
    /// unsigned build can make, since an explicit access control needs a signed process.
    public static func create(userPresence: Bool = true) throws -> EnclaveHolderKey {
        guard userPresence else { return EnclaveHolderKey(key: try SecureEnclave.P256.KeyAgreement.PrivateKey()) }
        let flags: SecAccessControlCreateFlags = [.privateKeyUsage, .userPresence]
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error)
        else { throw HolderKeyError.unusable(error.map { "\($0.takeRetainedValue())" } ?? "no access control") }
        return EnclaveHolderKey(key: try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access))
    }

    /// The key again from its data representation; `reason` is what the Touch ID prompt says.
    public init(storedRepresentation: Data, reason: String? = nil) throws {
        let context = LAContext()
        if let reason { context.localizedReason = reason }
        key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: storedRepresentation,
                                                               authenticationContext: context)
    }

    init(key: SecureEnclave.P256.KeyAgreement.PrivateKey) { self.key = key }

    public func agree(_ ephemeral: Data, into z: UnsafeMutableRawBufferPointer) throws {
        let shared = try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: ephemeral))
        shared.withUnsafeBytes { z.copyMemory(from: $0) }
    }
}

/// A software P-256 key, for Macs without a Secure Enclave (and for tests).
public struct SoftwareHolderKey: HolderKey {
    public let key: P256.KeyAgreement.PrivateKey
    public var kind: HolderKeyKind { .software }
    public var publicKey: Data { key.publicKey.x963Representation }
    public var storedRepresentation: Data { key.rawRepresentation }

    public init() { key = P256.KeyAgreement.PrivateKey() }

    public init(storedRepresentation: Data) throws { key = try P256.KeyAgreement.PrivateKey(rawRepresentation: storedRepresentation) }

    public func agree(_ ephemeral: Data, into z: UnsafeMutableRawBufferPointer) throws {
        let shared = try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: ephemeral))
        shared.withUnsafeBytes { z.copyMemory(from: $0) }
    }
}

/// Makes and reopens holder keys: the Secure Enclave where there is one, software otherwise.
public struct HolderKeys: Sendable {
    public var preferEnclave: Bool
    public var userPresence: Bool

    public init(preferEnclave: Bool = EnclaveHolderKey.isAvailable, userPresence: Bool = true) {
        self.preferEnclave = preferEnclave
        self.userPresence = userPresence
    }

    public func create() throws -> any HolderKey {
        preferEnclave ? try EnclaveHolderKey.create(userPresence: userPresence) : SoftwareHolderKey()
    }

    public func open(kind: HolderKeyKind, stored: Data, reason: String?) throws -> any HolderKey {
        switch kind {
        case .secureEnclave: try EnclaveHolderKey(storedRepresentation: stored, reason: reason)
        case .software: try SoftwareHolderKey(storedRepresentation: stored)
        }
    }
}

extension AccountKey {
    /// Opens KAK1 sealed to `holder` (suite 2) through the agreement callback.
    static func unwrap(_ kak1: Data, holder: any HolderKey, statement: KeyStatement) throws -> AccountKey {
        try AccountKey.unwrap(kak1, holderPublicKey: holder.publicKey, suite: .p256, statement: statement) { epk, z in
            try holder.agree(epk, into: z)
        }
    }
}

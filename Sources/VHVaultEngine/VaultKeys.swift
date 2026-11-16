import Foundation
public import VHCore
import Security

/// The vault keys this Mac holds for one vault, as the engine's keys table needs them (`vl_vaultfmt_keys_table`): a
/// version's 32 bytes copied into the library's buffer (which it wipes after taking them into locked memory), and the
/// version new objects are sealed under. Implementations never keep a copy outside their own store.
public protocol VaultKeySource: Sendable {
    func currentVersion() throws -> UInt32
    /// Copies the key of `version` into `buffer` (32 bytes); false when this Mac doesn't hold that version.
    func copyKey(version: UInt32, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool
}

/// Keys in memory (``SecretBytes``), for tests and for a vault key between its creation and the keychain.
public final class MemoryVaultKeys: VaultKeySource, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UInt32: SecretBytes]
    private var current: UInt32

    public init(_ keys: [UInt32: SecretBytes], current: UInt32) {
        self.keys = keys
        self.current = current
    }

    public func add(_ key: SecretBytes, version: UInt32, makeCurrent: Bool = true) {
        lock.withLock {
            keys[version] = key
            if makeCurrent { current = version }
        }
    }

    public func currentVersion() throws -> UInt32 { lock.withLock { current } }

    public func copyKey(version: UInt32, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        guard let key = lock.withLock({ keys[version] }), key.count == 32, buffer.count >= 32 else { return false }
        key.withUnsafeBytes { buffer.copyMemory(from: $0) }
        return true
    }
}

/// A fresh vault key: 32 bytes from the system's CSPRNG.
public func newVaultKey() -> SecretBytes {
    var raw = [UInt8](repeating: 0, count: 32)
    precondition(SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess)
    defer { raw.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
    return SecretBytes(raw)
}

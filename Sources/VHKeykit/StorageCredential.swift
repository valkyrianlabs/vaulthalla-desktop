public import Foundation
public import VHCore
import VLKeykit

/// The sealed storage credential (`\x89VHC`, vl-keykit `storage_credential.hpp`): a managed bucket's key secret, sealed
/// by Vaulthalla Cloud to a one-time X25519 key and bound to this installation, the vault and the key id. A Mac
/// holding a Desktop-only vault runs the same exchange as a server: ``CredentialKey/generate()``, send
/// ``CredentialKey/publicKey()``, ``CredentialKey/open(_:installationID:vaultUid:keyID:)`` the answer's
/// `sealed_secret`, then let the one-time key go.
public enum StorageCredential {
    public static let maxSecretSize = Int(VL_KEYKIT_CREDENTIAL_SECRET_MAX_SIZE)
    public static let maxKeyIDSize = Int(VL_KEYKIT_CREDENTIAL_KEY_ID_MAX_SIZE)
    public static let maxSealedSize = Int(VL_KEYKIT_CREDENTIAL_SEALED_MAX_SIZE)

    /// The cloud's side, for test doubles (a client never seals): `secret` sealed under the binding to `publicKey`.
    public static func seal(_ secret: SecretBytes, installationID: String, vaultUid: Data, keyID: String,
                            to publicKey: Data) throws(KeykitError) -> Data {
        try vaultUid.withFixed(16) { uid throws(KeykitError) in
            try publicKey.withFixed(32) { pk throws(KeykitError) in
                try output(maxSealedSize) { out, n in
                    secret.withUnsafeBytes { s in
                        installationID.withText { i, iN in
                            keyID.withText { k, kN in
                                vl_keykit_credential_seal(s.bindMemory(to: UInt8.self).baseAddress, s.count, i, iN, uid,
                                                          k, kN, pk, out, n)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The one-time X25519 key a storage credential is sealed to, inside vl-keykit's handle (zeroed when released). Make
/// a fresh one per request and release it once the answer is opened.
public final class CredentialKey: @unchecked Sendable {
    // Immutable after creation: the library allows concurrent reads of one handle.
    let handle: OpaquePointer

    init(handle: OpaquePointer) { self.handle = handle }
    deinit { vl_keykit_credential_key_free(handle) }

    /// A new key from the library's CSPRNG.
    public static func generate() throws(KeykitError) -> CredentialKey {
        var out: OpaquePointer?
        try check(vl_keykit_credential_key_generate(&out))
        return CredentialKey(handle: out!)
    }

    /// The key pair of a 32-byte X25519 secret held elsewhere (the golden vectors).
    public convenience init(secretKey: SecretBytes) throws(KeykitError) {
        guard secretKey.count == 32 else { throw KeykitError.invalidArgument }
        var out: OpaquePointer?
        let status = secretKey.withUnsafeBytes { raw in
            vl_keykit_credential_key_from_secret(raw.bindMemory(to: UInt8.self).baseAddress, &out)
        }
        try check(status)
        self.init(handle: out!)
    }

    /// The `public_key` the credential request sends (32 bytes; base64url on the wire).
    public func publicKey() throws(KeykitError) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        try check(vl_keykit_credential_key_public(handle, &out))
        return Data(out)
    }

    /// Opens a sealed credential bound to `installationID` (this Mac's 26-symbol id), `vaultUid` (16 bytes) and `keyID`
    /// (the answer's `key_id`). Any other binding fails as `credential_auth_failed`.
    public func open(_ sealed: Data, installationID: String, vaultUid: Data, keyID: String) throws(KeykitError) -> OpenedCredential {
        var out: OpaquePointer?
        let status = try vaultUid.withFixed(16) { uid in
            sealed.withBytes { s, sn in
                installationID.withText { i, iN in
                    keyID.withText { k, kN in vl_keykit_credential_open(s, sn, handle, i, iN, uid, k, kN, &out) }
                }
            }
        }
        try check(status)
        return OpenedCredential(handle: out!)
    }
}

/// An opened storage credential's secret, inside vl-keykit's handle (zeroed when released). It leaves the handle only
/// into a buffer for immediate use, which is zeroed as soon as `body` returns. Never printed.
public final class OpenedCredential: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let handle: OpaquePointer

    init(handle: OpaquePointer) { self.handle = handle }
    deinit { vl_keykit_credential_free(handle) }

    /// The secret's length.
    public var count: Int {
        var length = 0
        _ = vl_keykit_credential_secret(handle, nil, &length)
        return length
    }

    /// Reads the secret into a buffer of its own for `body` only; the buffer is zeroed afterwards.
    public func withSecret<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        var length = count
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(length, 1), alignment: 1)
        defer {
            _ = memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
            buffer.deallocate()
        }
        try check(vl_keykit_credential_secret(handle, buffer.bindMemory(to: UInt8.self).baseAddress, &length))
        return try body(UnsafeRawBufferPointer(rebasing: buffer[0 ..< length]))
    }

    /// The secret copied into a zeroing ``SecretBytes`` (to keep it in memory, or write it to the keychain).
    public func secretBytes() throws -> SecretBytes { try withSecret { SecretBytes($0) } }

    public var description: String { "OpenedCredential(redacted)" }
    public var debugDescription: String { description }
}

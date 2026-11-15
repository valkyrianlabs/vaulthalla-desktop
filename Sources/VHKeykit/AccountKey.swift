public import Foundation
public import VHCore
import VLKeykit

/// The account recovery key (a recovery seed) inside vl-keykit's handle: locked memory, zeroed when this is released.
/// The seed leaves it only as the recovery code (``recoveryCode()``).
public final class AccountKey: @unchecked Sendable {
    // Immutable after creation: the library allows concurrent reads of one handle.
    let handle: OpaquePointer

    init(handle: OpaquePointer) { self.handle = handle }
    deinit { vl_keykit_seed_free(handle) }

    /// A new account key from the library's CSPRNG.
    public static func generate() throws(KeykitError) -> AccountKey {
        var out: OpaquePointer?
        try check(vl_keykit_seed_generate(&out))
        return AccountKey(handle: out!)
    }

    /// The recovery code as a person types it (whitespace and '-' ignored, either case).
    public convenience init(recoveryCode: String) throws(KeykitError) {
        var out: OpaquePointer?
        try check(recoveryCode.withText { p, n in vl_keykit_seed_parse(p, n, &out) })
        self.init(handle: out!)
    }

    /// The recovery code typed into a secret buffer (27 ASCII symbols), parsed without a `String` copy.
    public convenience init(recoveryCode: SecretBytes) throws(KeykitError) {
        var out: OpaquePointer?
        let status = recoveryCode.withUnsafeBytes { raw in
            vl_keykit_seed_parse(raw.bindMemory(to: CChar.self).baseAddress, raw.count, &out)
        }
        try check(status)
        self.init(handle: out!)
    }

    /// The recovery code: 27 lower-case symbols, ungrouped. Show it, print it or save it, and let it go.
    public func recoveryCode() throws(KeykitError) -> SecretBytes {
        var buffer = [CChar](repeating: 0, count: Int(VL_KEYKIT_SEED_TEXT_SIZE))
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        var length = buffer.count
        try check(vl_keykit_seed_export_text(handle, &buffer, &length))
        return SecretBytes(buffer[0 ..< length].map { UInt8(bitPattern: $0) })
    }

    /// The X25519 recipient public key (servers wrap vault keys to it) and the Ed25519 statement signing key.
    public func publicKeys() throws(KeykitError) -> (x25519: Data, ed25519: Data) {
        var x = [UInt8](repeating: 0, count: 32)
        var e = [UInt8](repeating: 0, count: 32)
        try check(vl_keykit_seed_public_keys(handle, &x, &e))
        return (Data(x), Data(e))
    }

    /// Whether this is the key of `statement` (a recovery code typed in, against the statement the cloud serves).
    public func matches(_ statement: KeyStatement) -> Bool {
        statement.text.withText { p, n in vl_keykit_seed_matches(handle, p, n) } == Int32(VL_KEYKIT_OK)
    }

    // MARK: statements

    /// The canonical statement of this key as `generation` of the account `publicID`: generation 1 with no previous
    /// fingerprint and ``KeyReason/initial``, later ones the previous fingerprint and routine or compromise.
    public func statement(publicID: String, generation: UInt32, previous: Fingerprint?,
                          reason: KeyReason) throws(KeykitError) -> KeyStatement {
        let prev = previous.map { [UInt8]($0.bytes) }
        let text = try textOutput(Int(VL_KEYKIT_STATEMENT_MAX_SIZE)) { out, n in
            publicID.withText { id, idn in
                if let prev {
                    vl_keykit_statement_build(handle, id, idn, generation, prev, reason.rawValue, out, n)
                } else {
                    vl_keykit_statement_build(handle, id, idn, generation, nil, reason.rawValue, out, n)
                }
            }
        }
        return try KeyStatement(text)
    }

    /// Signs `statement` (this key's) and, for a rotation, with the previous generation's key too.
    public func sign(_ statement: KeyStatement, previous: AccountKey? = nil) throws(KeykitError) -> SignedStatement {
        var signature = [UInt8](repeating: 0, count: 64)
        var previousSignature = [UInt8](repeating: 0, count: 64)
        try check(statement.text.withText { p, n in
            vl_keykit_statement_sign(p, n, handle, previous?.handle, &signature, &previousSignature)
        })
        return SignedStatement(statement: statement.text, signature: Data(signature),
                               previousSignature: previous == nil ? nil : Data(previousSignature))
    }

    // MARK: holders and KAK1

    /// The holder proof for `POST /v1/keys/holders`: this key (of generation `statement`) signs the installation and
    /// its holder public key.
    public func holderProof(_ statement: KeyStatement, installationID: String, suite: KeySuite,
                            holderPublicKey: Data) throws(KeykitError) -> Data {
        var proof = [UInt8](repeating: 0, count: 64)
        try check(statement.text.withText { st, stn in
            installationID.withText { id, idn in
                holderPublicKey.withBytes { k, kn in
                    vl_keykit_holder_proof_sign(st, stn, handle, id, idn, suite.rawValue, k, kn, &proof)
                }
            }
        })
        return Data(proof)
    }

    /// This key, of generation `statement`, wrapped as KAK1 to a holder or transfer key of `suite`.
    public func wrap(_ statement: KeyStatement, suite: KeySuite, to publicKey: Data) throws(KeykitError) -> Data {
        try output(Int(VL_KEYKIT_KAK1_MAX_SIZE)) { out, n in
            statement.text.withText { st, stn in
                publicKey.withBytes { k, kn in vl_keykit_kak1_wrap(handle, st, stn, suite.rawValue, k, kn, out, n) }
            }
        }
    }

    /// Opens KAK1 with a holder secret key in memory (X25519: 32 bytes; P-256: the 32-byte scalar).
    public static func unwrap(_ kak1: Data, secretKey: SecretBytes, suite: KeySuite,
                              statement: KeyStatement) throws(KeykitError) -> AccountKey {
        var out: OpaquePointer?
        let status = kak1.withBytes { e, en in
            secretKey.withUnsafeBytes { sk in
                statement.text.withText { st, stn in
                    vl_keykit_kak1_unwrap(e, en, sk.bindMemory(to: UInt8.self).baseAddress, sk.count, suite.rawValue, st,
                                          stn, &out)
                }
            }
        }
        try check(status)
        return AccountKey(handle: out!)
    }

    /// Opens KAK1 with a key that never leaves its hardware: `agree` computes Z of the holder key with the envelope's
    /// ephemeral public key (32 bytes, or the 65-byte point) and writes its 32 bytes into the buffer it is given. It
    /// runs once, synchronously, after the envelope's structure, account, generation and recipient were checked. A
    /// throw (the person cancelled, the key is gone) is rethrown as it was.
    public static func unwrap(_ kak1: Data, holderPublicKey: Data, suite: KeySuite, statement: KeyStatement,
                              agree: (Data, UnsafeMutableRawBufferPointer) throws -> Void) throws -> AccountKey {
        try withoutActuallyEscaping(agree) { agree in
            let box = AgreementBox(agree)
            var out: OpaquePointer?
            let context = Unmanaged.passUnretained(box).toOpaque()
            let status = kak1.withBytes { e, en in
                holderPublicKey.withBytes { k, kn in
                    statement.text.withText { st, stn in
                        vl_keykit_kak1_unwrap_with(e, en, k, kn, suite.rawValue, st, stn, agreeTrampoline, context, &out)
                    }
                }
            }
            withExtendedLifetime(box) {}
            if let error = box.error { throw error }
            try check(status)
            return AccountKey(handle: out!)
        }
    }

    // MARK: labels, vault keys, the recovery policy

    /// Opens a vault's sealed label (`vh.vault-label.v1`) with this key of generation `statement`.
    public func openLabel(_ sealed: Data, statement: KeyStatement, vaultUid: Data) throws(KeykitError) -> String {
        try vaultUid.withFixed(16) { uid throws(KeykitError) in
            try textOutput(Int(VL_KEYKIT_LABEL_MAX_SIZE)) { out, n in
                sealed.withBytes { s, sn in
                    statement.text.withText { st, stn in vl_keykit_label_open(s, sn, handle, st, stn, uid, out, n) }
                }
            }
        }
    }

    /// Opens a KEV1 envelope addressed to this key's X25519 recipient for the vault `vaultUid` (16 bytes).
    public func openVaultKey(_ envelope: Data, vaultUid: Data) throws(KeykitError) -> VaultKey {
        var out: OpaquePointer?
        let status = try vaultUid.withFixed(16) { uid in
            envelope.withBytes { e, en in vl_keykit_kev1_unwrap(e, en, handle, uid, &out) }
        }
        try check(status)
        return VaultKey(handle: out!)
    }

    /// Builds and signs the account's next recovery policy under generation `statement`.
    public func signPolicy(_ statement: KeyStatement, sequence: UInt32, issuedAt: String,
                           recipients: [PolicyRecipient]) throws(KeykitError) -> SignedPolicy {
        let keys = recipients.map { [UInt8]($0.x25519PublicKey) }
        let labels = recipients.map { Array($0.label.utf8) }
        guard keys.allSatisfy({ $0.count == 32 }) else { throw KeykitError.invalidArgument }
        var signature = [UInt8](repeating: 0, count: 64)
        var policy = [CChar](repeating: 0, count: Int(VL_KEYKIT_POLICY_MAX_SIZE))
        var length = policy.count
        let status = withPointers(keys) { keyPointers in
            withPointers(labels) { labelPointers in
                var list: [vl_keykit_policy_recipient] = []
                for i in recipients.indices {
                    list.append(vl_keykit_policy_recipient(
                        x25519_public: keyPointers[i]!,
                        label: UnsafeRawPointer(labelPointers[i]!).assumingMemoryBound(to: CChar.self),
                        label_len: labels[i].count))
                }
                return statement.text.withText { st, stn in
                    issuedAt.withText { at, atn in
                        list.withUnsafeBufferPointer { l in
                            vl_keykit_policy_sign(handle, st, stn, sequence, at, atn, l.baseAddress, l.count, &policy,
                                                  &length, &signature)
                        }
                    }
                }
            }
        }
        try check(status)
        return SignedPolicy(policy: String(decoding: policy[0 ..< length].map { UInt8(bitPattern: $0) }, as: UTF8.self),
                            signature: Data(signature))
    }
}

/// A vault key opened from a KEV1 envelope, inside vl-keykit's handle, with its key version and vault.
public final class VaultKey: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) { self.handle = handle }
    deinit { vl_keykit_vault_key_free(handle) }

    public var keyVersion: UInt32 { vl_keykit_vault_key_version(handle) }

    /// Wraps the key again, under its own version and vault, to `publicKey` of `suite` (a restore's temporary key).
    public func wrap(suite: KeySuite, to publicKey: Data) throws(KeykitError) -> Data {
        try output(Int(VL_KEYKIT_KEV1_MAX_SIZE)) { out, n in
            publicKey.withBytes { k, kn in vl_keykit_kev1_wrap(handle, suite.rawValue, k, kn, out, n) }
        }
    }
}

// MARK: - the agreement callback

private final class AgreementBox {
    let agree: (Data, UnsafeMutableRawBufferPointer) throws -> Void
    var error: (any Error)?
    init(_ agree: @escaping (Data, UnsafeMutableRawBufferPointer) throws -> Void) { self.agree = agree }
}

private let agreeTrampoline: vl_keykit_agree_fn = { context, ephemeral, ephemeralLength, sharedSecret in
    guard let context, let ephemeral, let sharedSecret else { return 1 }
    let box = Unmanaged<AgreementBox>.fromOpaque(context).takeUnretainedValue()
    do {
        try box.agree(Data(bytes: ephemeral, count: ephemeralLength), UnsafeMutableRawBufferPointer(start: sharedSecret, count: 32))
        return 0
    } catch {
        box.error = error
        return 1
    }
}

/// Pointers to each array's bytes, valid for `body`.
private func withPointers<R>(_ arrays: [[UInt8]], _ body: ([UnsafePointer<UInt8>?]) -> R) -> R {
    var pointers: [UnsafePointer<UInt8>?] = []
    var buffers: [UnsafeMutableBufferPointer<UInt8>] = []
    defer { buffers.forEach { $0.deallocate() } }
    for a in arrays {
        let b = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(a.count, 1))
        _ = b.initialize(from: a)
        buffers.append(b)
        pointers.append(UnsafePointer(b.baseAddress))
    }
    return body(pointers)
}

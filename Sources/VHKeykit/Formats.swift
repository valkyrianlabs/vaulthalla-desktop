public import Foundation
import VLKeykit

/// The comparison codes two screens show (xxxx-xxxx-xxxx-xxxx). Desktop computes each itself: a code the cloud sends
/// is a convenience, never trusted.
public enum KeyCodes {
    /// A key request's code: its id and the payload text exactly as sent.
    public static func request(id: String, payload: String) throws(KeykitError) -> String {
        try textOutput(Int(VL_KEYKIT_CODE_TEXT_SIZE)) { out, n in
            id.withText { i, iN in payload.withText { p, pn in vl_keykit_request_code(i, iN, p, pn, out, n) } }
        }
    }

    /// A transfer's code: the account public id and the new device's temporary public key (32 or 65 bytes).
    public static func transfer(publicID: String, temporaryKey: Data) throws(KeykitError) -> String {
        try textOutput(Int(VL_KEYKIT_CODE_TEXT_SIZE)) { out, n in
            publicID.withText { i, iN in temporaryKey.withBytes { k, kn in vl_keykit_transfer_code(i, iN, k, kn, out, n) } }
        }
    }

    /// A restore's code: the vault uid text and the receiving installation's temporary X25519 key.
    public static func restore(vaultUid: String, temporaryKey: Data) throws(KeykitError) -> String {
        try textOutput(Int(VL_KEYKIT_CODE_TEXT_SIZE)) { out, n in
            vaultUid.withText { u, un in temporaryKey.withBytes { k, kn in vl_keykit_restore_code(u, un, k, kn, out, n) } }
        }
    }
}

/// The holder proof (`vhc-account-key-holder-v1`), checked.
public enum HolderProof {
    public static func verify(_ proof: Data, statement: KeyStatement, installationID: String, suite: KeySuite,
                              holderPublicKey: Data) throws(KeykitError) {
        let status = try proof.withFixed(64) { p in
            statement.text.withText { st, stn in
                installationID.withText { id, idn in
                    holderPublicKey.withBytes { k, kn in
                        vl_keykit_holder_proof_verify(st, stn, id, idn, suite.rawValue, k, kn, p)
                    }
                }
            }
        }
        try check(status)
    }
}

/// KAK1's prefix, read without a key (authenticating nothing).
public struct KAK1Header: Hashable, Sendable {
    public let suite: UInt16
    public let generation: UInt32
    public let publicID: Data
    public let fingerprint: Data
    public let recipientID: Data

    public init(_ envelope: Data) throws(KeykitError) {
        var h = vl_keykit_kak1_header()
        try check(envelope.withBytes { e, n in vl_keykit_kak1_inspect(e, n, &h) })
        suite = h.suite
        generation = h.generation
        publicID = bytes(of: h.public_id)
        fingerprint = bytes(of: h.fingerprint)
        recipientID = bytes(of: h.recipient_id)
    }
}

/// KEV1's prefix, read without a key (authenticating nothing).
public struct KEV1Header: Hashable, Sendable {
    public let suite: UInt16
    public let purpose: UInt8
    public let recipientClass: UInt8
    public let keyVersion: UInt32
    public let vaultUid: Data
    public let recipientID: Data

    public init(_ envelope: Data) throws(KeykitError) {
        var h = vl_keykit_kev1_header()
        try check(envelope.withBytes { e, n in vl_keykit_kev1_inspect(e, n, &h) })
        suite = h.suite
        purpose = h.purpose
        recipientClass = h.recipient_class
        keyVersion = h.key_version
        vaultUid = bytes(of: h.vault_uid)
        recipientID = bytes(of: h.recipient_id)
    }

    /// Whether a restore passes over an envelope that failed with `error` (another recipient's, a reserved purpose or
    /// recipient class) instead of failing.
    public static func isSkippedByRestore(_ error: KeykitError) -> Bool { vl_keykit_kev1_skipped_by_restore(error.status) != 0 }
}

/// Sealed vault labels (`vh.vault-label.v1`).
public enum VaultLabel {
    public static let sealedSize = Int(VL_KEYKIT_LABEL_SEALED_SIZE)

    /// Seals a vault's name for `vaultUid` (16 bytes) to the account key of `statement`.
    public static func seal(_ name: String, statement: KeyStatement, vaultUid: Data) throws(KeykitError) -> Data {
        try vaultUid.withFixed(16) { uid throws(KeykitError) in
            try output(sealedSize) { out, n in
                name.withText { nm, nn in statement.text.withText { st, stn in vl_keykit_label_seal(nm, nn, st, stn, uid, out, n) } }
            }
        }
    }
}

/// One recipient of the account's recovery policy besides the account key.
public struct PolicyRecipient: Hashable, Sendable {
    public var x25519PublicKey: Data
    public var label: String

    public init(x25519PublicKey: Data, label: String) {
        self.x25519PublicKey = x25519PublicKey
        self.label = label
    }
}

/// A signed recovery policy (`vhc-recovery-policy-v1`) and what verifying it found.
public struct SignedPolicy: Hashable, Sendable {
    public var policy: String
    public var signature: Data

    public init(policy: String, signature: Data) {
        self.policy = policy
        self.signature = signature
    }

    public struct Info: Hashable, Sendable {
        public let sequence: UInt32
        public let generation: UInt32
        public let recipients: [PolicyRecipient]
        public let sha256: Data
    }

    /// Verifies the policy against the pinned generation `statement` (the sequence floor is the caller's).
    public func verify(against statement: KeyStatement) throws(KeykitError) -> Info {
        var info = vl_keykit_policy_info()
        let status = try signature.withFixed(64) { sig in
            policy.withText { p, pn in statement.text.withText { st, stn in vl_keykit_policy_verify(p, pn, sig, st, stn, &info) } }
        }
        try check(status)
        var recipients: [PolicyRecipient] = []
        for i in 0 ..< Int(info.recipient_count) {
            var key = [UInt8](repeating: 0, count: 32)
            let label = try textOutput(Int(VL_KEYKIT_LABEL_MAX_SIZE)) { out, n in
                policy.withText { p, pn in vl_keykit_policy_recipient_at(p, pn, i, &key, out, n) }
            }
            recipients.append(PolicyRecipient(x25519PublicKey: Data(key), label: label))
        }
        return Info(sequence: info.sequence, generation: info.generation, recipients: recipients, sha256: bytes(of: info.hash))
    }
}

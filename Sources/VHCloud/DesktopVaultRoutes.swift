public import Foundation

// MARK: - the routes a Desktop-only vault's keys need

/// `PUT /v1/recovery/vaults/{uid}` (200): what enrolling stored (recovery `Enrollment.cpp`, `addRecoveryRoutes`).
public struct CloudEnrollment: Decodable, Sendable {
    public var created: Bool
    public var envelopesAdded: Int?
    public var versionsAdded: Int?
}

/// One envelope of `GET /v1/keys/vaults/{uid}/envelopes` (`KeyManager::envelopes`): to a generation of the account key.
public struct CloudVaultEnvelope: Decodable, Sendable {
    public var keyVersion: UInt32
    public var generation: UInt32
    public var fingerprint: String
    /// base64url KEV1.
    public var envelope: String
}

extension CloudClient {
    /// Enrolls a vault this Mac holds for recovery (key-manager.md "As built" 20): its envelopes (KEV1 to the account
    /// key, standard base64 as enrollment takes them) and key versions, with this Mac's provenance of the versions it
    /// created (recovery-enrollment.md, "A Mac's provenance"): its origin, its attestation key, each version's key
    /// check and attestation. Registers the vault as this Mac's if it is new (account-model.md "As built" 18).
    public func enrollDesktopVault(_ uid: String, envelopes: [Data], versions: [UInt32],
                                   provenance: VaultProvenance? = nil) async throws -> CloudEnrollment {
        struct Attestation: Encodable { var keyId: UInt32; var signature: String; var publicKey: String }
        struct Version: Encodable {
            var version: UInt32
            var keyCheck: String?
            var attestation: Attestation?
        }
        struct Origin: Encodable { var nodeId: String; var vaultId: UInt32 }
        struct PublicKey: Encodable { var keyId: UInt32; var publicKey: String }
        struct Body: Encodable {
            var origin: Origin?
            var attestationPublicKeys: [PublicKey]?
            var envelopes: [String]
            var keyVersions: [Version]
        }
        let attested = Dictionary(uniqueKeysWithValues: (provenance?.versions ?? []).map { ($0.version, $0) })
        let pk = provenance?.publicKey.base64EncodedString()
        let rows = Set(versions).union(attested.keys).sorted().map { v in
            Version(version: v, keyCheck: attested[v]?.keyCheck,
                    attestation: attested[v].map { Attestation(keyId: provenance!.keyID, signature: $0.signature.base64EncodedString(),
                                                               publicKey: pk!) })
        }
        return try await signed("PUT", "/v1/recovery/vaults/\(try Self.checkedUid(uid))",
                                body: Body(origin: provenance.map { Origin(nodeId: $0.nodeID, vaultId: $0.vaultID) },
                                           attestationPublicKeys: provenance.map { [PublicKey(keyId: $0.keyID, publicKey: pk!)] },
                                           envelopes: envelopes.map { $0.base64EncodedString() }, keyVersions: rows))
    }

    /// `PUT /v1/vaults/{uid}/label {label}` (204, Deployments.cpp): the vault's name sealed to the account key (240 bytes,
    /// base64url), from the Mac that holds it, as a server sends its replica's. The cloud checks the size and the
    /// structure, never the content (it can't open it): 400 `invalid_label`; a vault this Mac doesn't hold is 409
    /// `held_by_*` / `unplaced`, an unknown one 404 `no_such_vault`.
    public func putVaultLabel(_ uid: String, sealed: Data) async throws {
        struct Body: Encodable { var label: String }
        _ = try await signedData("PUT", "/v1/vaults/\(try Self.checkedUid(uid))/label",
                                 body: encode(Body(label: Base64URL.encode(sealed))))
    }

    /// `POST /v1/storage/vaults/{uid}/ejected` (204, ManagedStorage `reportConverted`): this Mac, the vault's writer, no
    /// longer depends on the cloud's managed storage for it (an ejection: the bucket becomes the customer's). The
    /// ejection waits for this report (up to `storage.eject_wait_hours`); repeating it changes nothing. 409
    /// `not_ejecting` when the vault's storage isn't being ejected.
    public func reportEjectionConverted(_ uid: String) async throws {
        try await signedEmpty("POST", "/v1/storage/vaults/\(try Self.checkedUid(uid))/ejected")
    }

    /// `GET /v1/storage/eject` (ManagedStorage `ejection`; a Desktop or the portal, never a server): the ejection's
    /// progress and, per vault being ejected, each writer's own conversion report.
    public func ejectionProgress() async throws -> CloudEjectionProgress { try await signed("GET", "/v1/storage/eject") }

    /// `GET /v1/keys/vaults/{uid}/envelopes`: the vault's envelopes to every generation of the account key (a linked
    /// Desktop may read any vault of its account). Nil when the vault isn't enrolled or the account has no key yet (404).
    public func vaultEnvelopes(_ uid: String) async throws -> [CloudVaultEnvelope]? {
        struct Reply: Decodable { var envelopes: [CloudVaultEnvelope] }
        do {
            let reply: Reply = try await signed("GET", "/v1/keys/vaults/\(try Self.checkedUid(uid))/envelopes")
            return reply.envelopes
        } catch CloudError.notFound {
            return nil
        }
    }
}

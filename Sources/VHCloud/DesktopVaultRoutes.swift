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
    /// key, standard base64 as enrollment takes them) and key versions. Registers the vault as this Mac's if it is new
    /// (account-model.md "As built" 18).
    public func enrollDesktopVault(_ uid: String, envelopes: [Data], versions: [UInt32]) async throws -> CloudEnrollment {
        struct Version: Encodable { var version: UInt32 }
        struct Body: Encodable {
            var envelopes: [String]
            var keyVersions: [Version]
        }
        return try await signed("PUT", "/v1/recovery/vaults/\(try Self.checkedUid(uid))",
                                body: Body(envelopes: envelopes.map { $0.base64EncodedString() },
                                           keyVersions: versions.map(Version.init)))
    }

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

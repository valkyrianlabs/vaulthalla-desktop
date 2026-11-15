public import Foundation

// The Vaulthalla Cloud routes Desktop reads and writes, as the daemon answers them (vaulthalla-cloud main:
// src/accounts, src/keys/KeyManager.cpp, src/billing, src/recovery; where a design document and the code disagree,
// these follow the code). Decoded with snake_case keys. Times are Unix seconds. Account key formats (statements,
// signatures, KAK1, holder keys, labels) are base64url without padding; KEV1 envelopes and restore keys standard base64.
// The cloud publishes no contract yet (docs/cloud-storage.md, Engineering): these are hand-written, and
// CloudModelsTests decodes the daemon's shapes.

/// `GET /v1/installation`: this Mac as the cloud records it.
public struct CloudInstallation: Codable, Hashable, Sendable {
    public var id: String
    public var accountPublicId: String
    public var deploymentId: String?
    public var name: String
    public var kind: String
}

/// `GET /v1/deployments`: one server of the account.
public struct CloudDeployment: Codable, Hashable, Sendable, Identifiable {
    public struct Installation: Codable, Hashable, Sendable {
        public var id: String
        public var fingerprint: String
    }

    public var id: String
    public var name: String
    /// The node id the server reported when it linked: a hint, until the node confirms it over its own connection.
    public var nodeId: String?
    public var createdAt: Int64
    public var lastSeen: Int64?
    public var installation: Installation?

    public init(id: String, name: String, nodeId: String?, createdAt: Int64 = 0, lastSeen: Int64? = nil,
                installation: Installation? = nil) {
        self.id = id
        self.name = name
        self.nodeId = nodeId
        self.createdAt = createdAt
        self.lastSeen = lastSeen
        self.installation = installation
    }
}

/// `GET /v1/vaults`: one vault of the account, by its uid, with the servers holding it.
public struct CloudVault: Codable, Hashable, Sendable, Identifiable {
    public struct Replica: Codable, Hashable, Sendable {
        public var deploymentId: String
        /// The vault's id on that server, when the server registered it (a restore's placement has none yet).
        public var originVaultId: Int64?
        public var addedAt: Int64

        public init(deploymentId: String, originVaultId: Int64?, addedAt: Int64 = 0) {
            self.deploymentId = deploymentId
            self.originVaultId = originVaultId
            self.addedAt = addedAt
        }
    }

    public var vaultUid: String
    /// The sealed name (`vh.vault-label.v1`, 240 bytes, base64url), opened with the account key; nil before a server
    /// sealed one.
    public var label: String?
    public var registeredAt: Int64
    public var replicas: [Replica]

    public var id: String { vaultUid }

    public init(vaultUid: String, label: String? = nil, registeredAt: Int64 = 0, replicas: [Replica]) {
        self.vaultUid = vaultUid
        self.label = label
        self.registeredAt = registeredAt
        self.replicas = replicas
    }
}

/// `GET /v1/keys/account`: the account recovery key's chain, the offline copy and the newest signed policy.
public struct CloudAccountKey: Codable, Hashable, Sendable {
    public struct Current: Codable, Hashable, Sendable {
        public var generation: UInt32
        public var fingerprint: String
        public var link: String
        public var offlineCopyConfirmedAt: Int64?
    }

    public struct Generation: Codable, Hashable, Sendable {
        public var generation: UInt32
        public var statement: String
        public var signature: String
        public var previousSignature: String?
        public var fingerprint: String
        public var reason: String
        public var link: String
        public var status: String
        public var createdAt: Int64
        public var retiredAt: Int64?
        public var offlineCopyConfirmedAt: Int64?
    }

    public struct Policy: Codable, Hashable, Sendable {
        public var sequence: UInt32
        public var generation: UInt32
        public var policy: String
        public var signature: String
        public var createdBy: String
        public var createdAt: Int64
    }

    public var publicId: String
    public var current: Current
    public var offlineCopyConfirmedAt: Int64?
    public var chain: [Generation]
    public var policy: Policy?
}

/// `GET /v1/keys/holders`, `POST /v1/keys/holders`: a Desktop that keeps the account key. Only this Mac's own row
/// carries its KAK1.
public struct CloudKeyHolder: Codable, Hashable, Sendable {
    public var installationId: String
    public var suite: UInt16
    public var holderPublicKey: String
    public var generation: UInt32
    public var proof: String
    public var addedAt: Int64
    public var updatedAt: Int64
    public var kak1: String?
}

/// `GET /v1/keys/account/unlocks`: how else the key unlocks (never ciphertext).
public struct CloudKeyUnlocks: Codable, Hashable, Sendable {
    public struct Unlock: Codable, Hashable, Sendable {
        public var id: String
        public var kind: String
        public var passkeyId: Int64
        public var generation: UInt32
        public var current: Bool
        public var createdAt: Int64
        public var lastUsedAt: Int64?
    }

    public var generation: UInt32?
    public var unlocks: [Unlock]
    public var holders: Int64
}

/// `POST /v1/keys/requests`, `GET /v1/keys/requests/{id}`: a change the account holder approves in the portal.
public struct CloudKeyRequest: Codable, Hashable, Sendable {
    public struct Requester: Codable, Hashable, Sendable {
        public var installationId: String
        public var name: String
        public var fingerprint: String
    }

    public var id: String
    public var action: String
    /// requested, approved, denied, expired, cancelled.
    public var status: String
    /// The cloud's copy of the code; Desktop shows the one it computes from the id and the payload it sent.
    public var requestCode: String
    public var requester: Requester
    public var createdAt: Int64
    public var expiresAt: Int64
    public var closedAt: Int64?
}

/// `POST /v1/keys/transfers`, `GET /v1/keys/transfers/{id}`, `GET /v1/keys/transfers/pending`.
public struct CloudKeyTransfer: Codable, Hashable, Sendable {
    public struct Requester: Codable, Hashable, Sendable {
        /// `installation:<id>`, or `session` for a browser.
        public var id: String
        public var name: String
    }

    public var id: String
    /// requested, delivered, completed, cancelled, expired.
    public var status: String
    public var suite: UInt16
    public var temporaryPublicKey: String
    public var transferCode: String
    public var requester: Requester
    public var deliveredBy: String?
    public var createdAt: Int64
    public var expiresAt: Int64
    /// Served to the requester once delivered.
    public var kak1: String?
}

/// `GET /v1/recovery/vaults`: a vault's recovery coverage, including the account key's per version.
public struct CloudRecoveryCoverage: Codable, Hashable, Sendable {
    public struct Version: Codable, Hashable, Sendable {
        public var version: UInt32
        public var attested: Bool
        public var accountKey: Bool
    }

    public struct AccountKeyCoverage: Codable, Hashable, Sendable {
        public var generation: UInt32
        public var missingVersions: [UInt32]
        public var covered: Bool
    }

    public var vaultUid: String
    public var versions: [Version]
    public var missingVersions: [UInt32]
    public var ready: Bool
    public var accountKey: AccountKeyCoverage?
}

/// `GET /v1/billing`: the plan's state in the cloud's words (never invoices or cards).
public struct CloudBilling: Codable, Hashable, Sendable {
    /// A number of vaults, or unlimited.
    public enum Allowance: Codable, Hashable, Sendable {
        case limited(Int64)
        case unlimited

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int64.self) { self = .limited(n) } else if (try? c.decode(String.self)) == "unlimited" {
                self = .unlimited
            } else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "a number or \"unlimited\"")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .limited(let n): try c.encode(n)
            case .unlimited: try c.encode("unlimited")
            }
        }
    }

    public struct RecoveryVaults: Codable, Hashable, Sendable {
        public var allowance: Allowance
        public var enrolled: Int64?
    }

    public struct Next: Codable, Hashable, Sendable {
        public var state: String
        public var at: Int64?
    }

    /// active, past_due, restricted, suspended, ended; nil on the default plan without a subscription.
    public var state: String?
    public var stateSince: Int64?
    public var plan: String
    public var storageQuotaBytes: Int64
    public var recoveryVaults: RecoveryVaults
    public var storageAccess: String
    public var next: Next?
    public var deletionAt: Int64?
    public var currentPeriodEnd: Int64?
    public var cancelAtPeriodEnd: Bool
}

/// `GET /v1/billing/plans`.
public struct CloudPlans: Codable, Hashable, Sendable {
    public struct Plan: Codable, Hashable, Sendable {
        public var plan: String
        public var storageQuotaBytes: Int64
        public var recoveryVaults: CloudBilling.Allowance
    }

    public var plans: [Plan]
}

/// `POST /v1/billing/handoffs`: a one-use link the browser redeems with the account holder's session.
public struct CloudBillingHandoff: Codable, Hashable, Sendable {
    public var id: String
    public var url: String
    public var expiresAt: Int64?
}

/// The daemon's error body: `{"error": {"code", "message"}}`.
struct CloudErrorBody: Decodable {
    struct Inner: Decodable {
        var code: String?
        var message: String?
    }

    var error: Inner?
}

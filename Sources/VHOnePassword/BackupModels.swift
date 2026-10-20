public import Foundation
public import VHCore

/// The result of `account.check`.
public struct OnePasswordAccountStatus: Sendable, Equatable, Decodable {
    public let account: String
    public let connected: Bool
    public let vaultCount: Int

    enum CodingKeys: String, CodingKey {
        case account, connected
        case vaultCount = "vault_count"
    }
}

/// The 1Password vault holding the backups (`Vaulthalla` by default).
public struct OnePasswordVault: Sendable, Equatable, Decodable {
    public let id: String
    public let title: String
    /// True when `vault.ensure` had to create it.
    public let created: Bool

    enum CodingKeys: String, CodingKey {
        case id = "vault_id"
        case title, created
    }
}

/// One key version as 1Password stores it: number, key check and state, never the key.
public struct StoredKeyVersion: Sendable, Equatable, Hashable, Decodable {
    public enum State: Sendable, Equatable, Hashable {
        case current, needed, retired
        case other(String)

        init(_ raw: String?) {
            switch raw {
            case "current": self = .current
            case "needed": self = .needed
            case "retired": self = .retired
            default: self = .other(raw ?? "")
            }
        }
    }

    public let version: Int
    public let keyCheck: String
    public let state: State

    public init(version: Int, keyCheck: String, state: State) {
        self.version = version
        self.keyCheck = keyCheck
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case version, state
        case keyCheck = "key_check"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        keyCheck = try c.decode(String.self, forKey: .keyCheck)
        state = State(try c.decodeIfPresent(String.self, forKey: .state))
    }
}

/// What 1Password holds for one Vaulthalla vault: identifiers and key checks only. Desktop stores just `itemID`.
public struct BackupItem: Sendable, Equatable, Identifiable, Decodable {
    public var id: String { itemID }
    public let itemID: String
    /// The 1Password vault the item is in.
    public let onePasswordVaultID: String
    public let title: String
    public let nodeID: String
    public let nodeName: String
    /// The Vaulthalla vault's id.
    public let vaultUUID: String
    public let vaultName: String
    public let currentVersion: Int
    public let keyCheck: String
    /// Newest first.
    public let versions: [StoredKeyVersion]
    public let updatedAt: Date?
    public let backedUpAt: Date?
    /// Inconsistencies the helper found in the item (hand edits, damage). Non-empty means `mismatch`.
    public let issues: [String]

    public init(
        itemID: String, onePasswordVaultID: String, title: String = "", nodeID: String, nodeName: String = "",
        vaultUUID: String, vaultName: String = "", currentVersion: Int, keyCheck: String,
        versions: [StoredKeyVersion], updatedAt: Date? = nil, backedUpAt: Date? = nil, issues: [String] = []
    ) {
        self.itemID = itemID
        self.onePasswordVaultID = onePasswordVaultID
        self.title = title
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.vaultUUID = vaultUUID
        self.vaultName = vaultName
        self.currentVersion = currentVersion
        self.keyCheck = keyCheck
        self.versions = versions
        self.updatedAt = updatedAt
        self.backedUpAt = backedUpAt
        self.issues = issues
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case onePasswordVaultID = "vault_id"
        case title
        case nodeID = "node_id"
        case nodeName = "node_name"
        case vaultUUID = "vault_uuid"
        case vaultName = "vault_name"
        case currentVersion = "current_version"
        case keyCheck = "key_check"
        case versions
        case updatedAt = "updated_at"
        case backedUpAt = "backed_up_at"
        case issues
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(String.self, forKey: .itemID)
        onePasswordVaultID = try c.decode(String.self, forKey: .onePasswordVaultID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        nodeID = try c.decode(String.self, forKey: .nodeID)
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName) ?? ""
        vaultUUID = try c.decode(String.self, forKey: .vaultUUID)
        vaultName = try c.decodeIfPresent(String.self, forKey: .vaultName) ?? ""
        currentVersion = try c.decode(Int.self, forKey: .currentVersion)
        keyCheck = try c.decode(String.self, forKey: .keyCheck)
        versions = try c.decodeIfPresent([StoredKeyVersion].self, forKey: .versions) ?? []
        // Lenient: backed_up_at is an item field a user could edit; a bad value must not break the whole list.
        updatedAt = parseTimestamp(try c.decodeIfPresent(String.self, forKey: .updatedAt))
        backedUpAt = parseTimestamp(try c.decodeIfPresent(String.self, forKey: .backedUpAt))
        issues = try c.decodeIfPresent([String].self, forKey: .issues) ?? []
    }

    public func version(_ number: Int) -> StoredKeyVersion? {
        versions.first { $0.version == number }
    }
}

func parseTimestamp(_ text: String?) -> Date? {
    guard let text, !text.isEmpty else { return nil }
    return try? Date(text, strategy: .iso8601)
}

/// A key version with its key, going to 1Password (`upsert`) or coming back (`reveal`).
public struct KeyVersion: Sendable {
    public let version: Int
    public let key: SecretBytes
    public let keyCheck: String
    /// The daemon still needs this version to decrypt files.
    public let needed: Bool

    public init(version: Int, key: SecretBytes, keyCheck: String, needed: Bool) {
        self.version = version
        self.key = key
        self.keyCheck = keyCheck
        self.needed = needed
    }
}

/// Everything `item.upsert` needs for one (node, vault).
public struct BackupUpsert: Sendable {
    /// The 1Password vault (from `ensureVault`).
    public var onePasswordVaultID: String
    public var nodeID: String
    public var nodeName: String
    public var vaultUUID: String
    public var vaultName: String
    public var currentVersion: Int
    /// The daemon's export: the current key and every version still needed.
    public var versions: [KeyVersion]

    public init(
        onePasswordVaultID: String, nodeID: String, nodeName: String, vaultUUID: String, vaultName: String,
        currentVersion: Int, versions: [KeyVersion]
    ) {
        self.onePasswordVaultID = onePasswordVaultID
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.vaultUUID = vaultUUID
        self.vaultName = vaultName
        self.currentVersion = currentVersion
        self.versions = versions
    }
}

/// What 1Password holds after an upsert, read back by the helper. Confirm the export to the daemon
/// (`vault.keys.export.confirm`) with `currentVersion` and `keyCheck` from here, not from the request.
public struct BackupUpsertOutcome: Sendable, Equatable, Decodable {
    public let itemID: String
    public let onePasswordVaultID: String
    public let created: Bool
    /// False when 1Password already held exactly this (nothing was written).
    public let written: Bool
    public let currentVersion: Int
    public let keyCheck: String
    public let storedVersions: [StoredKeyVersion]
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case onePasswordVaultID = "vault_id"
        case created, written
        case currentVersion = "current_version"
        case keyCheck = "key_check"
        case storedVersions = "stored_versions"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(String.self, forKey: .itemID)
        onePasswordVaultID = try c.decode(String.self, forKey: .onePasswordVaultID)
        created = try c.decode(Bool.self, forKey: .created)
        written = try c.decode(Bool.self, forKey: .written)
        currentVersion = try c.decode(Int.self, forKey: .currentVersion)
        keyCheck = try c.decode(String.self, forKey: .keyCheck)
        storedVersions = try c.decode([StoredKeyVersion].self, forKey: .storedVersions)
        updatedAt = parseTimestamp(try c.decodeIfPresent(String.self, forKey: .updatedAt))
    }
}

/// Key material read back from 1Password, for restore and export only (D7).
public struct RevealedKeys: Sendable {
    public let itemID: String
    public let onePasswordVaultID: String
    public let nodeID: String
    public let vaultUUID: String
    public let currentVersion: Int
    /// Newest first (or in the order requested).
    public let versions: [KeyVersion]
}

/// The reveal result as decoded from the redacted line; keys are attached from `ResponseLine.secrets`.
struct WireReveal: Decodable {
    struct Version: Decodable {
        let version: Int
        let keyCheck: String
        let state: String?

        enum CodingKeys: String, CodingKey {
            case version, state
            case keyCheck = "key_check"
        }
    }

    let itemID: String
    let vaultID: String
    let nodeID: String
    let vaultUUID: String
    let currentVersion: Int
    let versions: [Version]

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case vaultID = "vault_id"
        case nodeID = "node_id"
        case vaultUUID = "vault_uuid"
        case currentVersion = "current_version"
        case versions
    }
}

struct WireItems: Decodable {
    let items: [BackupItem]
}

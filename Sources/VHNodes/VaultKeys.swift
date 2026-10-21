public import Foundation
public import VHContract
public import VHCore
public import VHTransport

/// One vault's keys as the daemon exported them (`vault.keys.export`), key material in `SecretBytes`. Hand them on
/// (to 1Password) and drop them: nothing here is persisted, logged or kept.
public struct ExportedVaultKeys: Sendable {
    public struct Version: Sendable {
        public let version: Int
        public let key: SecretBytes
        public let keyCheck: String
        /// `current`, `rotation` (an unfinished rotation's outgoing key), `recovery`, or a newer daemon's word.
        public let reason: String
        /// The node's attestation of this version, when the daemon attests keys (absent: not attested).
        public let nodeID: String?
        public let attestation: KeyAttestation?
    }

    public let vaultID: Int64
    public let vaultName: String
    public let currentVersion: Int
    /// The current version first, then the other needed versions.
    public let versions: [Version]
    /// Needed versions the node no longer holds (never invented).
    public let missingVersions: [Int]
    public let deleted: Bool
}

/// Keys going back to a node (`vault.keys.import`) or into a file, in the shape `vh vault keys export` writes.
public struct VaultKeySet: Sendable {
    public struct Version: Sendable {
        public let version: Int
        public let key: SecretBytes
        public let keyCheck: String?
        public let reason: String?
        /// Passed back byte for byte, so the daemon can verify the version as its own (recover mode).
        public let nodeID: String?
        public let attestation: KeyAttestation?

        public init(version: Int, key: SecretBytes, keyCheck: String?, reason: String? = nil, nodeID: String? = nil,
                    attestation: KeyAttestation? = nil) {
            self.version = version
            self.key = key
            self.keyCheck = keyCheck
            self.reason = reason
            self.nodeID = nodeID
            self.attestation = attestation
        }
    }

    public let vaultID: Int64
    public let vaultName: String
    public let currentVersion: Int
    public let versions: [Version]

    /// `currentVersion` is the backup's current version; when the set doesn't hold it, the newest version it holds
    /// stands in as `key`.
    public init(vaultID: Int64, vaultName: String, currentVersion: Int, versions: [Version]) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.currentVersion = currentVersion
        self.versions = versions
    }

    /// Writes the export object: `{vault_id, vault_name, key, key_check, node_id?, attestation?, key_info: {key_version,
    /// key_check, ...}, historical_keys: [{key_version, key, key_check, node_id?, attestation?}]}` (the daemon's
    /// `generate_json_key_object` plus key checks and attestations; the import reads `key`, `key_info.key_version` /
    /// `key_check` and every `historical_keys[]` entry).
    public func write(to w: SecretJSONWriter, exportedBy: String, exportedAt: Date = .now) {
        let sorted = versions.sorted { $0.version > $1.version }
        guard let head = sorted.first(where: { $0.version == currentVersion }) ?? sorted.first else {
            w.beginObject()
            w.field("vault_id", vaultID)
            w.field("vault_name", vaultName)
            w.endObject()
            return
        }
        w.beginObject()
        w.field("vault_id", vaultID)
        w.field("vault_name", vaultName)
        w.key("key")
        w.base64(head.key)
        Self.writeIdentity(head, to: w)
        w.key("key_info")
        w.beginObject()
        w.field("type", "AES-256-GCM")
        w.field("key_size", head.key.count)
        w.field("key_version", head.version)
        w.field("iv_size", 12)
        w.field("tag_size", 16)
        w.field("exported_by", exportedBy)
        w.field("exported_at", exportedAt.formatted(.iso8601))
        Self.writeIdentity(head, to: w)
        w.endObject()
        let others = sorted.filter { $0.version != head.version }.reversed() // ascending, as the daemon writes them
        if !others.isEmpty {
            w.key("historical_keys")
            w.beginArray()
            for version in others {
                w.beginObject()
                w.field("key_version", version.version)
                w.key("key")
                w.base64(version.key)
                Self.writeIdentity(version, to: w)
                if let reason = version.reason { w.field("reason", reason) }
                w.endObject()
            }
            w.endArray()
        }
        w.endObject()
    }

    private static func writeIdentity(_ version: Version, to w: SecretJSONWriter) {
        if let check = version.keyCheck { w.field("key_check", check) }
        if let node = version.nodeID { w.field("node_id", node) }
        if let attestation = version.attestation {
            w.key("attestation")
            w.beginObject()
            w.field("key_id", attestation.keyID)
            w.field("signature", attestation.signature)
            w.endObject()
        }
    }
}

/// How `vault.keys.import` treats the keys.
public enum VaultKeyImportMode: String, Sendable, Hashable {
    /// The default: a version is restored as the vault's own only when its attestation verifies; others come back
    /// `needs_salvage`. Confirmation `vault_key_import`.
    case recover
    /// For versions without a valid attestation: the daemon decrypts what it can, re-encrypts it under a fresh key
    /// and reports the files it couldn't recover. Confirmation `vault_key_salvage`.
    case salvage

    /// The daemon's confirmation code for writing in this mode (the vault's name, typed).
    public var confirmationCode: String {
        switch self {
        case .recover: "vault_key_import"
        case .salvage: "vault_key_salvage"
        }
    }
}

/// `vault.keys.import`'s answer, decoded leniently: the vendored contract (`VaultKeyImportResult`) predates the
/// attestation and salvage fields, so members it doesn't have are optional here. Re-check against the contract when it
/// is re-vendored.
public struct VaultKeyImportReport: Sendable, Equatable, Decodable {
    public struct Version: Sendable, Equatable, Decodable, Identifiable {
        public var id: Int { version }
        public let version: Int
        /// `restored`, `unchanged`, `unverifiable`, `needs_salvage`, or a newer daemon's word.
        public let outcome: String
        public let detail: String
        public let verifiedFiles: Int
        public let failedFiles: Int

        public init(version: Int, outcome: String, detail: String = "", verifiedFiles: Int = 0, failedFiles: Int = 0) {
            self.version = version
            self.outcome = outcome
            self.detail = detail
            self.verifiedFiles = verifiedFiles
            self.failedFiles = failedFiles
        }

        enum CodingKeys: String, CodingKey {
            case version, outcome, detail
            case verifiedFiles = "verified_files"
            case failedFiles = "failed_files"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            outcome = try c.decode(String.self, forKey: .outcome)
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            verifiedFiles = try c.decodeIfPresent(Int.self, forKey: .verifiedFiles) ?? 0
            failedFiles = try c.decodeIfPresent(Int.self, forKey: .failedFiles) ?? 0
        }

        public static let needsSalvage = "needs_salvage"
    }

    /// What a salvage did: files re-encrypted under a fresh key, and those it couldn't decrypt.
    public struct Salvage: Sendable, Equatable, Decodable {
        public let newKeyVersion: Int?
        public let recoveredFiles: Int
        public let unrecoverableCount: Int
        /// The unrecoverable files' paths, as far as the daemon lists them.
        public let unrecoverableFiles: [String]

        public init(newKeyVersion: Int?, recoveredFiles: Int, unrecoverableCount: Int, unrecoverableFiles: [String]) {
            self.newKeyVersion = newKeyVersion
            self.recoveredFiles = recoveredFiles
            self.unrecoverableCount = unrecoverableCount
            self.unrecoverableFiles = unrecoverableFiles
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        private struct File: Decodable {
            let path: String
            init(from decoder: any Decoder) throws {
                if let text = try? decoder.singleValueContainer().decode(String.self) {
                    path = text
                } else {
                    let c = try decoder.container(keyedBy: Key.self)
                    path = try c.decodeIfPresent(String.self, forKey: Key("path"))
                        ?? c.decode(String.self, forKey: Key("name"))
                }
            }
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            func int(_ names: String...) -> Int? {
                for name in names { if let v = try? c.decodeIfPresent(Int.self, forKey: Key(name)) { return v } }
                return nil
            }
            var files: [String] = []
            for name in ["unrecoverable_files", "unrecoverable"] {
                if let list = try? c.decodeIfPresent([File].self, forKey: Key(name)) { files = list.map(\.path); break }
            }
            newKeyVersion = int("new_key_version", "key_version", "new_version")
            recoveredFiles = int("recovered_files", "files_recovered", "recovered") ?? 0
            unrecoverableCount = int("unrecoverable_count", "files_unrecoverable", "unrecoverable_files") ?? files.count
            unrecoverableFiles = files
        }
    }

    public let vaultID: Int64
    public let vaultName: String
    public let deleted: Bool
    /// False when every version was unchanged or skipped.
    public let written: Bool
    /// The vault runs on this host now: the only answer that means "recovered".
    public let keyAvailable: Bool
    public let note: String?
    public let versions: [Version]
    public let salvage: Salvage?

    public init(vaultID: Int64, vaultName: String, deleted: Bool = false, written: Bool, keyAvailable: Bool,
                note: String? = nil, versions: [Version], salvage: Salvage? = nil) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.deleted = deleted
        self.written = written
        self.keyAvailable = keyAvailable
        self.note = note
        self.versions = versions
        self.salvage = salvage
    }

    enum CodingKeys: String, CodingKey {
        case vaultID = "vault_id"
        case vaultName = "vault_name"
        case deleted, written, note, versions, salvage
        case keyAvailable = "key_available"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vaultID = try c.decode(Int64.self, forKey: .vaultID)
        vaultName = try c.decodeIfPresent(String.self, forKey: .vaultName) ?? ""
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        written = try c.decodeIfPresent(Bool.self, forKey: .written) ?? false
        keyAvailable = try c.decodeIfPresent(Bool.self, forKey: .keyAvailable) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        versions = try c.decodeIfPresent([Version].self, forKey: .versions) ?? []
        salvage = try c.decodeIfPresent(Salvage.self, forKey: .salvage)
    }

    /// Versions the daemon couldn't verify as the vault's own: only a salvage can use them.
    public var needsSalvage: [Version] { versions.filter { $0.outcome == Version.needsSalvage } }
}

/// The export answer with the optional attestation members (absent until the daemon attests keys). Keys are the
/// `secret:<n>` placeholders `SecretJSON.lift` left.
private struct ExportWire: Decodable {
    struct Info: Decodable {
        let keyVersion: Int64
        let keyCheck: String?
        let nodeID: String?
        let attestation: KeyAttestation?

        enum CodingKeys: String, CodingKey {
            case keyVersion = "key_version"
            case keyCheck = "key_check"
            case nodeID = "node_id"
            case attestation
        }
    }

    struct Historical: Decodable {
        let keyVersion: Int64
        let key: String
        let keyCheck: String
        let reason: String?
        let nodeID: String?
        let attestation: KeyAttestation?

        enum CodingKeys: String, CodingKey {
            case keyVersion = "key_version"
            case key
            case keyCheck = "key_check"
            case reason
            case nodeID = "node_id"
            case attestation
        }
    }

    let vaultID: Int64
    let vaultName: String
    let key: String
    let keyCheck: String
    let keyInfo: Info
    let nodeID: String?
    let attestation: KeyAttestation?
    let historicalKeys: [Historical]?
    let missingKeyVersions: [Int64]?
    let deletedVault: Bool?

    enum CodingKeys: String, CodingKey {
        case vaultID = "vault_id"
        case vaultName = "vault_name"
        case key
        case keyCheck = "key_check"
        case keyInfo = "key_info"
        case nodeID = "node_id"
        case attestation
        case historicalKeys = "historical_keys"
        case missingKeyVersions = "missing_key_versions"
        case deletedVault = "deleted_vault"
    }
}

/// The `vault.keys.*` commands on one node. Status and confirm are ordinary typed requests; export and import carry
/// keys, so they go through `NodeTransport.sendSensitive` and never touch a `Codable` key string: the export's keys
/// are lifted out of the answer frame into `SecretBytes` before the rest is decoded, and the import's payload is
/// written straight from `SecretBytes`. The daemon refuses export and import outside a paired Device session (D4).
public struct VaultKeyCommands: Sendable {
    public let transport: any NodeTransport

    public init(_ transport: any NodeTransport) {
        self.transport = transport
    }

    /// Every vault the account may inspect (`vault.keys.status`), or one.
    public func status(vaultID: Int64? = nil) async throws(WsError) -> [WsModel.VaultKeyStatus] {
        try await transport.send(Ws.Vault.Keys.Status.self, payload: .init(vaultID: vaultID.map { .value($0) })).vaults
    }

    /// The vault's current key and every version it still needs, with their attestations when the node gives them.
    public func export(vaultID: Int64) async throws(WsError) -> ExportedVaultKeys {
        let command = WsCommand.vaultKeysExport
        let writer = SecretJSONWriter(capacity: 64)
        writer.beginObject()
        writer.field("vault_id", vaultID)
        writer.endObject()
        let frame = try await transport.sendSensitive(command, payload: writer.finish())
        let lifted: SecretJSON.Lifted
        do {
            lifted = try frame.withUnsafeBytes { raw throws(SecretJSON.Failure) in
                try SecretJSON.lift(raw, members: ["key"])
            }
        } catch {
            throw .contractMismatch("\(command.rawValue): a key isn't base64")
        }
        let export = try WsClient.decodeAnswer(ExportWire.self, frame: lifted.redacted, command: command.rawValue)
        guard let current = lifted.secret(for: export.key) else {
            throw .contractMismatch("\(command.rawValue): the current key is missing")
        }
        let currentVersion = export.keyInfo.keyVersion
        var versions = [ExportedVaultKeys.Version(
            version: Int(currentVersion), key: current, keyCheck: export.keyCheck,
            reason: WsModel.VaultKeyNeededVersion.Reason.current,
            nodeID: export.nodeID ?? export.keyInfo.nodeID, attestation: export.attestation ?? export.keyInfo.attestation)]
        for historical in export.historicalKeys ?? [] {
            guard let key = lifted.secret(for: historical.key) else {
                throw .contractMismatch("\(command.rawValue): key version \(historical.keyVersion) is missing")
            }
            guard historical.keyVersion != currentVersion else { continue }
            versions.append(.init(version: Int(historical.keyVersion), key: key, keyCheck: historical.keyCheck,
                                  reason: historical.reason ?? WsModel.VaultKeyNeededVersion.Reason.recovery,
                                  nodeID: historical.nodeID ?? export.nodeID, attestation: historical.attestation))
        }
        return ExportedVaultKeys(
            vaultID: export.vaultID, vaultName: export.vaultName, currentVersion: Int(currentVersion),
            versions: versions, missingVersions: (export.missingKeyVersions ?? []).map(Int.init),
            deleted: export.deletedVault ?? false)
    }

    /// Records that 1Password stored `version`; refused (`conflict`) when it is no longer current or the check differs.
    public func confirm(vaultID: Int64, version: Int, keyCheck: String) async throws(WsError)
        -> Ws.Vault.Keys.Export.Confirm.Response
    {
        try await transport.send(Ws.Vault.Keys.Export.Confirm.self,
                                 payload: .init(vaultID: vaultID, version: Int64(version), keyCheck: keyCheck))
    }

    /// Puts keys back. Without `confirmName` the daemon plans first: nothing to write answers at once; otherwise it
    /// refuses with `needsConfirmation(code: mode.confirmationCode, message:)` saying what it would write, and the
    /// person confirms by typing the vault's name. `recover` (the default) leaves `mode` out, so a daemon from before
    /// attestations reads the request as it always did.
    public func importKeys(
        _ keys: VaultKeySet, mode: VaultKeyImportMode = .recover, confirmName: String? = nil, exportedBy: String
    ) async throws(WsError) -> VaultKeyImportReport {
        let command = WsCommand.vaultKeysImport
        let writer = SecretJSONWriter(capacity: 1024 + keys.versions.count * 400)
        writer.beginObject()
        writer.field("vault_id", keys.vaultID)
        writer.key("keys")
        keys.write(to: writer, exportedBy: exportedBy)
        if mode != .recover { writer.field("mode", mode.rawValue) }
        if let confirmName { writer.field("confirm_name", confirmName) }
        writer.endObject()
        let frame = try await transport.sendSensitive(command, payload: writer.finish())
        // The answer carries no keys; it is decoded from a copy that is zeroed right after.
        var copy = frame.withUnsafeBytes { Data($0) }
        defer { copy.resetBytes(in: 0..<copy.count) }
        return try WsClient.decodeAnswer(VaultKeyImportReport.self, frame: copy, command: command.rawValue)
    }
}

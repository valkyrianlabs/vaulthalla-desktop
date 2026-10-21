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

        public init(version: Int, key: SecretBytes, keyCheck: String?, reason: String? = nil) {
            self.version = version
            self.key = key
            self.keyCheck = keyCheck
            self.reason = reason
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

    /// Writes the export object: `{vault_id, vault_name, key, key_check, key_info: {key_version, key_check, ...},
    /// historical_keys: [...]}` (the daemon's `generate_json_key_object` plus key checks; the import reads `key`,
    /// `key_info.key_version`/`key_check` and every `historical_keys[]` entry's `key`, `key_version`, `key_check`).
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
        if let check = head.keyCheck { w.field("key_check", check) }
        w.key("key_info")
        w.beginObject()
        w.field("type", "AES-256-GCM")
        w.field("key_size", head.key.count)
        w.field("key_version", head.version)
        w.field("iv_size", 12)
        w.field("tag_size", 16)
        w.field("exported_by", exportedBy)
        w.field("exported_at", exportedAt.formatted(.iso8601))
        if let check = head.keyCheck { w.field("key_check", check) }
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
                if let check = version.keyCheck { w.field("key_check", check) }
                if let reason = version.reason { w.field("reason", reason) }
                w.endObject()
            }
            w.endArray()
        }
        w.endObject()
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

    /// The vault's current key and every version it still needs.
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
        let export = try WsClient.decodeAnswer(WsModel.VaultKeyExport.self, frame: lifted.redacted,
                                               command: command.rawValue)
        guard let current = lifted.secret(for: export.key) else {
            throw .contractMismatch("\(command.rawValue): the current key is missing")
        }
        var versions = [ExportedVaultKeys.Version(
            version: Int(export.keyInfo.keyVersion), key: current, keyCheck: export.keyCheck,
            reason: WsModel.VaultKeyNeededVersion.Reason.current)]
        for historical in export.historicalKeys ?? [] {
            guard let key = lifted.secret(for: historical.key) else {
                throw .contractMismatch("\(command.rawValue): key version \(historical.keyVersion) is missing")
            }
            guard historical.keyVersion != export.keyInfo.keyVersion else { continue }
            versions.append(.init(version: Int(historical.keyVersion), key: key, keyCheck: historical.keyCheck,
                                  reason: historical.reason))
        }
        return ExportedVaultKeys(
            vaultID: export.vaultID, vaultName: export.vaultName, currentVersion: Int(export.keyInfo.keyVersion),
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

    /// Puts keys back. Without `confirmName` the daemon plans first: nothing to write answers `unchanged`; otherwise it
    /// refuses with `needsConfirmation(code: "vault_key_import", message:)` saying what it would write, and the
    /// person confirms by typing the vault's name.
    public func importKeys(_ keys: VaultKeySet, confirmName: String? = nil, exportedBy: String)
        async throws(WsError) -> WsModel.VaultKeyImportResult
    {
        let command = WsCommand.vaultKeysImport
        let writer = SecretJSONWriter(capacity: 1024 + keys.versions.count * 160)
        writer.beginObject()
        writer.field("vault_id", keys.vaultID)
        writer.key("keys")
        keys.write(to: writer, exportedBy: exportedBy)
        if let confirmName { writer.field("confirm_name", confirmName) }
        writer.endObject()
        let frame = try await transport.sendSensitive(command, payload: writer.finish())
        // The answer carries no keys; it is decoded from a copy that is zeroed right after.
        var copy = frame.withUnsafeBytes { Data($0) }
        defer { copy.resetBytes(in: 0..<copy.count) }
        return try WsClient.decodeAnswer(WsModel.VaultKeyImportResult.self, frame: copy, command: command.rawValue)
    }
}

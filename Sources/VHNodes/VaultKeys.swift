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
        /// The node's attestation of this version; nil when it has none recorded (the version can then only be
        /// salvaged from a backup, never restored as the vault's own).
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
        /// The node's attestation as 1Password stored it, passed back unchanged: the daemon restores the version as
        /// the vault's own only when it verifies (recover mode).
        public let attestation: KeyAttestation?

        public init(version: Int, key: SecretBytes, keyCheck: String?, reason: String? = nil,
                    attestation: KeyAttestation? = nil) {
            self.version = version
            self.key = key
            self.keyCheck = keyCheck
            self.reason = reason
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

    /// Writes the export object: `{vault_id, vault_name, key, key_check, attestation, key_info: {key_version,
    /// key_check, attestation, ...}, historical_keys: [{key_version, key, key_check, attestation}]}` (the daemon's
    /// `VaultKeyExport`; `attestation` is `{key_id, signature}` or null). The import reads `key`,
    /// `key_info.key_version`, `key_check` and `attestation` (top level or in `key_info`), and every
    /// `historical_keys[]` entry.
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
        w.key("attestation")
        if let attestation = version.attestation {
            w.beginObject()
            w.field("key_id", attestation.keyID)
            w.field("signature", attestation.signature)
            w.endObject()
        } else {
            w.null()
        }
    }
}

/// How `vault.keys.import` treats the keys (the contract's `mode`).
///
/// - `recover` (the default): restores only key versions the vault had, proven by the node's own attestation; it never
///   sets a key of the caller's own. Other versions come back `needs_salvage`, nothing written for them. Confirmation
///   `vault_key_import`.
/// - `salvage`: recovers first, then re-encrypts the files the supplied keys still open under a fresh key the node
///   creates, reporting the files it couldn't open; the supplied keys are never stored. Confirmation
///   `vault_key_salvage`.
public typealias VaultKeyImportMode = Ws.Vault.Keys.Import.Payload.Mode

extension VaultKeyImportMode {
    /// The daemon's confirmation code for writing in this mode (the vault's name, typed).
    public var confirmationCode: String {
        switch self {
        case .recover: "vault_key_import"
        case .salvage: "vault_key_salvage"
        }
    }

    /// Every confirmation an import may ask for. A salvage that ends up with nothing to salvage asks as a recover.
    public static let confirmationCodes: Set<String> = Set(allCases.map(\.confirmationCode))
}

/// `vault.keys.import`'s answer: the contract's `VaultKeyImportResult` (`{vault_id, vault_name, deleted, mode, written,
/// key_available, note, versions: [{version, outcome, detail}], salvage}`).
public typealias VaultKeyImportReport = WsModel.VaultKeyImportResult

extension WsModel.VaultKeyImportResult {
    /// Versions the node can't prove are the vault's own (no valid attestation): only a salvage can use them.
    public var needsSalvage: [Version] { versions.filter { $0.outcome == Version.Outcome.needsSalvage } }

    /// Versions the vault never had: an import never introduces one.
    public var refused: [Version] { versions.filter { $0.outcome == Version.Outcome.refused } }

    /// The mode the node ran, when it is one this app knows.
    public var importMode: VaultKeyImportMode? { VaultKeyImportMode(rawValue: mode) }
}

extension WsModel.VaultKeySalvageReport {
    /// The pass was interrupted: running the salvage again resumes it.
    public var isRunning: Bool { state == State.running }

    /// Files it didn't re-encrypt, all kinds together.
    public var notSalvaged: Int64 { unrecoverable + skippedRemote + deferred + failed }

    /// Failures the report lists by name: at most 50, the first ones; the counts cover the rest.
    public static let listedFailures = 50

    /// Failures beyond the listed ones.
    public var unlistedFailures: Int64 { max(0, notSalvaged - Int64(failures.count)) }
}

extension KeyAttestation {
    /// The contract's attestation, kept as the daemon sent it.
    init(_ attestation: WsModel.VaultKeyAttestation) {
        self.init(keyID: attestation.keyID, signature: attestation.signature)
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
        let export = try WsClient.decodeAnswer(WsModel.VaultKeyExport.self, frame: lifted.redacted,
                                               command: command.rawValue)
        guard let current = lifted.secret(for: export.key) else {
            throw .contractMismatch("\(command.rawValue): the current key is missing")
        }
        let currentVersion = export.keyInfo.keyVersion
        var versions = [ExportedVaultKeys.Version(
            version: Int(currentVersion), key: current, keyCheck: export.keyCheck,
            reason: WsModel.VaultKeyNeededVersion.Reason.current,
            attestation: (export.attestation?.wrapped ?? export.keyInfo.attestation?.wrapped).map(KeyAttestation.init))]
        for historical in export.historicalKeys ?? [] {
            guard let key = lifted.secret(for: historical.key) else {
                throw .contractMismatch("\(command.rawValue): key version \(historical.keyVersion) is missing")
            }
            guard historical.keyVersion != currentVersion else { continue }
            versions.append(.init(version: Int(historical.keyVersion), key: key, keyCheck: historical.keyCheck,
                                  reason: historical.reason,
                                  attestation: historical.attestation?.wrapped.map(KeyAttestation.init)))
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

    /// Puts keys back (`vault.keys.import {vault_id, keys, mode, confirm_name?}`). Without `confirmName` the daemon
    /// plans first: nothing to write answers at once; otherwise it refuses with `needsConfirmation(code:message:)`
    /// (`vault_key_import` or `vault_key_salvage`) saying what it would do, and the person confirms by typing the
    /// vault's name.
    public func importKeys(
        _ keys: VaultKeySet, mode: VaultKeyImportMode = .recover, confirmName: String? = nil, exportedBy: String
    ) async throws(WsError) -> VaultKeyImportReport {
        let command = WsCommand.vaultKeysImport
        let writer = SecretJSONWriter(capacity: 1024 + keys.versions.count * 400)
        writer.beginObject()
        writer.field("vault_id", keys.vaultID)
        writer.key("keys")
        keys.write(to: writer, exportedBy: exportedBy)
        writer.field("mode", mode.rawValue)
        if let confirmName { writer.field("confirm_name", confirmName) }
        writer.endObject()
        let frame = try await transport.sendSensitive(command, payload: writer.finish())
        // The answer carries no keys; it is decoded from a copy that is zeroed right after.
        var copy = frame.withUnsafeBytes { Data($0) }
        defer { copy.resetBytes(in: 0..<copy.count) }
        return try WsClient.decodeAnswer(VaultKeyImportReport.self, frame: copy, command: command.rawValue)
    }
}

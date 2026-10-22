public import VHOnePassword

/// Where vault keys are backed up: 1Password through the bundled helper (`OnePasswordHelper`), or a stand-in (the
/// app's PREVIEW DATA). Keys go in and come out as `SecretBytes` only.
public protocol KeyBackupStore: Sendable {
    /// Connects to the account (1Password may ask for Touch ID). Required before the others.
    func checkAccount(_ account: String) async throws -> OnePasswordAccountStatus
    /// Finds the vault with this title, or creates it.
    func ensureVault(title: String) async throws -> OnePasswordVault
    /// Every backup item's metadata: identifiers, versions and key checks, never keys.
    func listItems(onePasswordVaultID: String) async throws -> [BackupItem]
    /// Writes one (node, vault)'s versions and returns what 1Password holds afterwards, read back.
    func upsert(_ backup: BackupUpsert) async throws -> BackupUpsertOutcome
    /// Reads keys back out, for a restore or an export file only. All versions when `versions` is nil.
    func reveal(onePasswordVaultID: String, itemID: String, versions: [Int]?) async throws -> RevealedKeys
    /// Adds the node's attestations to versions an item holds, as metadata: no key moves, and a well-formed
    /// attestation the item has is kept.
    func attest(_ update: AttestationUpdate) async throws -> AttestationUpdateOutcome
}

extension OnePasswordHelper: KeyBackupStore {}

/// The 1Password side of the backups, as the user set it up (Settings → 1Password).
public struct OnePasswordSettings: Sendable, Hashable, Codable {
    /// The account's name as 1Password's sidebar shows it, or its id.
    public var account: String
    /// The 1Password vault holding the items; created on the first sync.
    public var vaultTitle: String

    public static let defaultVaultTitle = "Vaulthalla"

    public init(account: String, vaultTitle: String = OnePasswordSettings.defaultVaultTitle) {
        self.account = account
        self.vaultTitle = vaultTitle
    }

    public var isConfigured: Bool {
        !account.trimmingCharacters(in: .whitespaces).isEmpty && !vaultTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

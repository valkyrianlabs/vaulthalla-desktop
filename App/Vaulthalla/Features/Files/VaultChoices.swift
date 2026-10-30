import Foundation
import VHContract
import VHNodes
import VHTransport

/// A vault the Files picker offers.
struct VaultChoice: Identifiable, Hashable {
    enum Access: Hashable {
        /// The account may list the vault's root: the browser can open it.
        case browse
        /// Only its settings (admin vault View): listed so it isn't a mystery, but it can't be opened here.
        case manageOnly
        /// Reached (owner, a role) without either: a role that grants nothing at the root, or ownership alone.
        case none
    }

    var id: Int64
    var name: String
    var owner: String?
    var isActive: Bool
    var access: Access
    /// The daemon's reasons (`owner`, `vault_role`, `group_role`, `admin_policy`, `super_admin`); empty from the
    /// older list.
    var via: [String]

    var canOpen: Bool { access == .browse && isActive }

    /// Why the account reaches it, for a tooltip ("You own it · Your vault role").
    var reasons: String {
        via.map { reason in
            switch reason {
            case "owner": "You own it"
            case "vault_role": "Your vault role"
            case "group_role": "A group's vault role"
            case "admin_policy": "Your admin role"
            case "super_admin": "Super admin"
            default: reason
            }
        }
        .joined(separator: " · ")
    }

    init(_ row: WsModel.AccessibleVault) {
        id = row.id
        name = row.name
        owner = row.owner.isEmpty ? nil : row.owner
        isActive = row.isActive
        access = row.browse ? .browse : (row.manage ? .manageOnly : .none)
        via = row.via
    }

    /// `storage.vault.list` (a daemon without the accessible list): what it lists, the account may manage; whether it
    /// may browse is only known by trying, as before.
    init(legacy vault: WsModel.Vault) {
        id = vault.id
        name = vault.name
        owner = vault.owner.flatMap { $0.isEmpty ? nil : $0 }
        isActive = vault.isActive
        access = .browse
        via = []
    }
}

/// The picker's source: `storage.vault.accessible.list` (every vault the account reaches, with what it may do there,
/// decided by the daemon's own permission checks), or `storage.vault.list` when the daemon predates it: its
/// `meta.hello` doesn't list the command, or (a legacy node, which lists nothing) it answers "Unknown command".
@MainActor
struct VaultChoices {
    let accessible: NodeQuery<Ws.Storage.Vault.Accessible.List>
    let legacy: NodeQuery<Ws.Storage.Vault.List>
    private let support: ProtocolSupport

    init(queries: NodeQueries) {
        accessible = queries.query(Ws.Storage.Vault.Accessible.List.self)
        legacy = queries.query(Ws.Storage.Vault.List.self)
        support = queries.supports(command: .storageVaultAccessibleList)
    }

    /// The daemon doesn't know the accessible list: read the older one instead.
    var usesLegacy: Bool {
        switch support {
        case .yes: return false
        case .no: return true
        case .unknown:
            if case .failed(let error) = accessible.state { return error.isUnknownCommand }
            return false
        }
    }

    /// Keeps whichever list the node answers fresh while a view shows it (`.task(id: observation)`).
    func observe() async {
        if usesLegacy { await legacy.observe() } else { await accessible.observe() }
    }

    /// Changes when ``observe()`` should restart: another node's queries, or the other list.
    var observation: Observation { Observation(query: ObjectIdentifier(accessible), legacy: usesLegacy) }

    struct Observation: Hashable {
        var query: ObjectIdentifier
        var legacy: Bool
    }

    var state: QueryState<[VaultChoice]> {
        if usesLegacy {
            return switch legacy.state {
            case .idle: .idle
            case .loading: .loading
            case .failed(let error): .failed(error)
            case .loaded(let value, let at): .loaded(value.vaults.map(VaultChoice.init(legacy:)), at: at)
            }
        }
        return switch accessible.state {
        case .idle: .idle
        case .loading: .loading
        case .failed(let error): .failed(error)
        case .loaded(let value, let at): .loaded(value.vaults.map(VaultChoice.init), at: at)
        }
    }

    var choices: [VaultChoice] {
        if case .loaded(let choices, _) = state { return choices }
        return []
    }

    /// Vaults the browser can open.
    var openable: [VaultChoice] { choices.filter(\.canOpen) }

    /// Vaults listed but not openable here: management only, no file access, or inactive.
    var unopenable: [VaultChoice] { choices.filter { !$0.canOpen } }

    func refresh() async {
        if usesLegacy { await legacy.refresh() } else { await accessible.refresh() }
    }

}

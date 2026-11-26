public import Foundation
public import Observation
public import VHCore

/// How the person likes to see their nodes on this Mac: favourites and muted notifications (docs/mac-experience.md
/// §5). View preferences, not credentials, so they live in `UserDefaults` by node id and not in the registry, which
/// only the credential owner may write. Nothing here is secret.
@MainActor
@Observable
public final class NodePreferences {
    public static let favoritesKey = "nodes.favorites"
    public static let mutedKey = "nodes.notificationsMuted"

    public private(set) var favorites: Set<NodeID>
    /// Nodes whose notifications are off. A muted node also stays out of the menu bar item's state.
    public private(set) var muted: Set<NodeID>

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Self.read(Self.favoritesKey, from: defaults)
        muted = Self.read(Self.mutedKey, from: defaults)
    }

    public func isFavorite(_ id: NodeID) -> Bool { favorites.contains(id) }

    public func setFavorite(_ favorite: Bool, for id: NodeID) {
        guard favorite != favorites.contains(id) else { return }
        if favorite { favorites.insert(id) } else { favorites.remove(id) }
        write(favorites, to: Self.favoritesKey)
    }

    public func toggleFavorite(_ id: NodeID) {
        setFavorite(!isFavorite(id), for: id)
    }

    public func isMuted(_ id: NodeID) -> Bool { muted.contains(id) }

    public func setMuted(_ mute: Bool, for id: NodeID) {
        guard mute != muted.contains(id) else { return }
        if mute { muted.insert(id) } else { muted.remove(id) }
        write(muted, to: Self.mutedKey)
    }

    /// The node was removed: its preferences go with it.
    public func forget(_ id: NodeID) {
        setFavorite(false, for: id)
        setMuted(false, for: id)
    }

    /// Favourites first, each group in the order given (the sidebar's).
    public func favoritesFirst(_ nodes: [Node]) -> [Node] {
        nodes.filter { favorites.contains($0.id) } + nodes.filter { !favorites.contains($0.id) }
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> Set<NodeID> {
        Set((defaults.stringArray(forKey: key) ?? []).map { NodeID(rawValue: $0) })
    }

    private func write(_ ids: Set<NodeID>, to key: String) {
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(ids.map(\.rawValue).sorted(), forKey: key)
        }
    }
}

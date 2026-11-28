public import Foundation
public import VHContract

/// This server's part in a mirrored vault (`mirror.list` / `mirror.get` `role`). A role this build doesn't know (a
/// newer daemon) stays `.other` and reads as itself, never as one of the known ones.
public enum MirrorRole: Hashable, Sendable {
    case core, mirror, orphaned, starting, detached, none
    case other(String)

    public init(_ raw: String) {
        switch raw {
        case "core": self = .core
        case "mirror": self = .mirror
        case "orphaned": self = .orphaned
        case "starting": self = .starting
        case "detached": self = .detached
        case "none": self = .none
        default: self = .other(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .core: "core"
        case .mirror: "mirror"
        case .orphaned: "orphaned"
        case .starting: "starting"
        case .detached: "detached"
        case .none: "none"
        case .other(let raw): raw
        }
    }

    /// The vault holds another server's copy here (what `mirror.detach.preview` answers for).
    public var holdsCopy: Bool { self == .mirror || self == .orphaned }
}

/// The mirror's state (`state`); nil on the row means the server didn't say. An unknown word stays `.other`.
public enum MirrorState: Hashable, Sendable {
    case starting, live, paused, diverged, expired, stopped, switching, rejoining, forked
    case other(String)

    public init(_ raw: String) {
        switch raw {
        case "starting": self = .starting
        case "live": self = .live
        case "paused": self = .paused
        case "diverged": self = .diverged
        case "expired": self = .expired
        case "stopped": self = .stopped
        case "switching": self = .switching
        case "rejoining": self = .rejoining
        case "forked": self = .forked
        default: self = .other(raw)
        }
    }
}

/// A status color as the console names it. `neutral` is for ended or inert rows; `unknown` for what the server
/// didn't say. Neither is ever green.
public enum MirrorTone: String, Hashable, Sendable {
    case ok, info, warn, danger, neutral, unknown
}

/// The link to the vault's other server, as the row reports it.
public enum MirrorLink: Hashable, Sendable {
    case up, down, unknown
    /// The linked server was unlinked (its row revoked).
    case unlinked
}

/// One mirrored vault on one node, from `mirror.list` or `mirror.get` (the same row). Every value the server didn't
/// send stays nil; nothing is filled in.
public struct MirroredVault: Identifiable, Hashable, Sendable {
    public struct Peer: Hashable, Sendable {
        public var id: Int64
        public var nodeID: String
        public var name: String
        public var revoked: Bool

        public init(id: Int64, nodeID: String, name: String, revoked: Bool) {
            self.id = id
            self.nodeID = nodeID
            self.name = name
            self.revoked = revoked
        }
    }

    /// A (term, seq) position.
    public struct Position: Hashable, Sendable {
        public var term: Int64
        public var seq: Int64

        public init(term: Int64, seq: Int64) {
            self.term = term
            self.seq = seq
        }
    }

    public struct Grant: Hashable, Sendable {
        public var roleName: String
        public var grantedAt: Int64
    }

    public struct Start: Hashable, Sendable {
        public var id: Int64
        /// This server's part in it: `core` or `mirror`.
        public var side: String
        /// `offered`, `pending`, `accepted`, `keys_acked`, `installed`, `started`, `declined`, `cancelled`, `expired`,
        /// `failed` (and newer words).
        public var state: String
        public var step: String
        public var name: String
        public var reason: String?
        public var lastError: String?
        public var expiresAt: Int64

        public init(id: Int64, side: String, state: String, step: String = "", name: String, reason: String? = nil,
                    lastError: String? = nil, expiresAt: Int64 = 0) {
            self.id = id
            self.side = side
            self.state = state
            self.step = step
            self.name = name
            self.reason = reason
            self.lastError = lastError
            self.expiresAt = expiresAt
        }
    }

    public struct Switch: Hashable, Sendable {
        public var side: String
        public var phase: String
        public var reason: String?
    }

    public struct Takeover: Hashable, Sendable {
        public var term: Int64
        public var fork: Position
        public var peerID: Int64
        public var contentsMissing: Int64
        public var createdAt: Int64

        public init(term: Int64, fork: Position, peerID: Int64, contentsMissing: Int64, createdAt: Int64) {
            self.term = term
            self.fork = fork
            self.peerID = peerID
            self.contentsMissing = contentsMissing
            self.createdAt = createdAt
        }
    }

    public struct Detached: Hashable, Sendable {
        /// `mirror`: detached here; `core`: its mirror left with a copy.
        public var side: String
        public var detachedAt: Int64
        public var rekeyRecommended: Bool

        public init(side: String, detachedAt: Int64, rekeyRecommended: Bool) {
            self.side = side
            self.detachedAt = detachedAt
            self.rekeyRecommended = rekeyRecommended
        }
    }

    public struct Deleting: Hashable, Sendable {
        public var deleting: Bool
        public var purgeAfter: Int64
        /// `leave` or `remove`.
        public var copy: String
        /// On a mirror: what this server will do by its keep setting.
        public var here: String?

        public init(deleting: Bool, purgeAfter: Int64, copy: String, here: String? = nil) {
            self.deleting = deleting
            self.purgeAfter = purgeAfter
            self.copy = copy
            self.here = here
        }
    }

    public struct FirstCopy: Hashable, Sendable {
        public var finished: Bool
        /// Mirror: the entries applied so far; nil on the core.
        public var entriesCopied: Int64?
        /// nil once the baseline is dropped.
        public var entriesTotal: Int64?

        public init(finished: Bool, entriesCopied: Int64? = nil, entriesTotal: Int64? = nil) {
            self.finished = finished
            self.entriesCopied = entriesCopied
            self.entriesTotal = entriesTotal
        }
    }

    public struct Settings: Hashable, Sendable {
        public struct Versions: Hashable, Sendable {
            public var enabled: Bool
            public var keepLast: Int64?
            public var maxAgeDays: Int64?
            public var quotaBytes: Int64?

            public init(enabled: Bool, keepLast: Int64? = nil, maxAgeDays: Int64? = nil, quotaBytes: Int64? = nil) {
                self.enabled = enabled
                self.keepLast = keepLast
                self.maxAgeDays = maxAgeDays
                self.quotaBytes = quotaBytes
            }
        }

        /// A mirror row only; nil on the core.
        public var versions: Versions?
        public var acceptAll: Bool
        public var keepRemoved: Bool
        public var mirrorAll: Bool

        public init(versions: Versions? = nil, acceptAll: Bool, keepRemoved: Bool, mirrorAll: Bool) {
            self.versions = versions
            self.acceptAll = acceptAll
            self.keepRemoved = keepRemoved
            self.mirrorAll = mirrorAll
        }
    }

    public var vaultID: Int64
    public var vaultName: String
    public var role: MirrorRole
    public var peer: Peer?
    public var term: Int64?
    public var lastSeq: Int64?
    public var state: MirrorState?
    public var grant: Grant?
    public var acked: Position?
    public var createdAt: Int64?
    public var start: Start?
    public var `switch`: Switch?
    public var takeover: Takeover?
    /// The server's own next step, when the vault waits on the other server.
    public var advice: String?
    public var detached: Detached?
    public var rekeyRecommended: Bool
    public var deleting: Deleting?
    public var stopReason: String?
    /// Mirror: changes made here the core hasn't confirmed; core: changes the mirror hasn't acknowledged (this term).
    public var pendingChanges: Int64
    public var firstCopy: FirstCopy?
    /// As sent: whether the link to the row's linked server is up. Read ``link`` instead.
    public var linkUp: Bool
    /// When the last position was acknowledged.
    public var confirmedAt: Int64?
    public var settings: Settings?

    public init(vaultID: Int64, vaultName: String, role: MirrorRole, peer: Peer? = nil, term: Int64? = nil,
                lastSeq: Int64? = nil, state: MirrorState? = nil, grant: Grant? = nil, acked: Position? = nil,
                createdAt: Int64? = nil, start: Start? = nil, switch: Switch? = nil, takeover: Takeover? = nil,
                advice: String? = nil, detached: Detached? = nil, rekeyRecommended: Bool = false,
                deleting: Deleting? = nil, stopReason: String? = nil, pendingChanges: Int64 = 0,
                firstCopy: FirstCopy? = nil, linkUp: Bool = false, confirmedAt: Int64? = nil,
                settings: Settings? = nil) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.role = role
        self.peer = peer
        self.term = term
        self.lastSeq = lastSeq
        self.state = state
        self.grant = grant
        self.acked = acked
        self.createdAt = createdAt
        self.start = start
        self.switch = `switch`
        self.takeover = takeover
        self.advice = advice
        self.detached = detached
        self.rekeyRecommended = rekeyRecommended
        self.deleting = deleting
        self.stopReason = stopReason
        self.pendingChanges = pendingChanges
        self.firstCopy = firstCopy
        self.linkUp = linkUp
        self.confirmedAt = confirmedAt
        self.settings = settings
    }

    /// Unique within one node's list: a start whose vault doesn't exist here yet has vault id 0.
    public var id: String { "\(vaultID)-\(start?.id ?? 0)-\(role.rawValue)" }

    /// The vault's name, or the offered name while its vault doesn't exist here yet.
    public var displayName: String {
        if !vaultName.isEmpty { return vaultName }
        if let name = start?.name, !name.isEmpty { return name }
        return "—"
    }

    /// The link to the other server: unknown without one, unlinked once its row is revoked, else as reported.
    public var link: MirrorLink {
        guard let peer else { return .unknown }
        if peer.revoked { return .unlinked }
        return linkUp ? .up : .down
    }

    /// Whether the link is up, for the status and advice rules: nil while unknown (never up by guess).
    public var linkIsUp: Bool? {
        switch link {
        case .up: true
        case .down, .unlinked: false
        case .unknown: nil
        }
    }

    /// The row has a mirror record (core or mirror side): position, pending changes and confirmation mean something.
    public var hasMirrorRecord: Bool { role == .core || role == .mirror }
}

// MARK: - From the contract

extension MirroredVault {
    /// A `mirror.get` row.
    public init(_ row: Ws.Mirror.Get.Response.Vault) {
        self.init(
            vaultID: row.vaultID, vaultName: row.vaultName, role: MirrorRole(row.role),
            peer: row.peer.map { Peer(id: $0.id, nodeID: $0.nodeID, name: $0.name, revoked: $0.revoked) },
            term: row.term, lastSeq: row.lastSeq, state: row.state.map(MirrorState.init),
            grant: row.grant.map { Grant(roleName: $0.roleName, grantedAt: $0.grantedAt) },
            acked: row.acked.map { Position(term: $0.term, seq: $0.seq) }, createdAt: row.createdAt,
            start: row.start.map {
                Start(id: $0.id, side: $0.side, state: $0.state, step: $0.step, name: $0.name, reason: $0.reason,
                      lastError: $0.lastError, expiresAt: $0.expiresAt)
            },
            switch: row.switch.map { Switch(side: $0.side, phase: $0.phase, reason: $0.reason) },
            takeover: row.takeover.map {
                Takeover(term: $0.term, fork: Position(term: $0.fork.term, seq: $0.fork.seq), peerID: $0.peerID,
                         contentsMissing: $0.contentsMissing, createdAt: $0.createdAt)
            },
            advice: row.advice,
            detached: row.detached.map {
                Detached(side: $0.side, detachedAt: $0.detachedAt, rekeyRecommended: $0.rekeyRecommended)
            },
            rekeyRecommended: row.rekeyRecommended,
            deleting: row.deleting.map {
                Deleting(deleting: $0.deleting, purgeAfter: $0.purgeAfter, copy: $0.copy, here: $0.here)
            },
            stopReason: row.stopReason, pendingChanges: row.pendingChanges,
            firstCopy: row.firstCopy.map {
                FirstCopy(finished: $0.finished, entriesCopied: $0.entriesCopied, entriesTotal: $0.entriesTotal)
            },
            linkUp: row.linkUp, confirmedAt: row.confirmedAt,
            settings: row.settings.map(Settings.init))
    }

    /// A `mirror.list` row. The contract generates it as its own type with the same members as `mirror.get`'s, so it
    /// is read through that one mapping; should the two ever differ, the row reads as the server not saying how the
    /// mirror stands (role and state unknown), never as healthy.
    public init(_ row: Ws.Mirror.List.Response.Vault) {
        do {
            let same = try JSONDecoder().decode(Ws.Mirror.Get.Response.Vault.self, from: JSONEncoder().encode(row))
            self.init(same)
        } catch {
            self.init(vaultID: row.vaultID, vaultName: row.vaultName, role: MirrorRole(row.role),
                      peer: row.peer.map { Peer(id: $0.id, nodeID: $0.nodeID, name: $0.name, revoked: $0.revoked) })
        }
    }
}

extension MirroredVault.Settings {
    init(_ wire: WsModel.MirrorSettings) {
        self.init(
            versions: wire.versions.map {
                Versions(enabled: $0.enabled, keepLast: $0.keepLast, maxAgeDays: $0.maxAgeDays, quotaBytes: $0.quotaBytes)
            },
            acceptAll: wire.acceptAll, keepRemoved: wire.keepRemoved, mirrorAll: wire.mirrorAll)
    }
}

/// What `mirror.detach.preview` adds to a held copy's detail (it changes nothing): whether the copies matched,
/// the held changes, and the files whose contents aren't here.
public struct MirrorHeldCopyFacts: Hashable, Sendable {
    public var digestMatched: Bool?
    /// Changes made here the core hasn't confirmed yet.
    public var pendingChanges: Int64
    public var heldChanges: Int64
    public var missingCount: Int64

    public init(digestMatched: Bool?, pendingChanges: Int64, heldChanges: Int64, missingCount: Int64) {
        self.digestMatched = digestMatched
        self.pendingChanges = pendingChanges
        self.heldChanges = heldChanges
        self.missingCount = missingCount
    }

    public init(_ preview: Ws.Mirror.Detach.Preview.Response.Preview) {
        self.init(digestMatched: preview.digestMatched, pendingChanges: preview.pendingChanges,
                  heldChanges: preview.heldChanges, missingCount: preview.missingCount)
    }
}

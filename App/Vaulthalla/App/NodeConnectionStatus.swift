import VHCore

/// Where Desktop stands with one node's device listener. Only a live transport may report `.connecting` or
/// `.online`; without one, a node is `.notPaired`, `.offline` or `.revoked`, derived from its saved pairing state.
enum NodeConnectionStatus: Hashable, Sendable {
    case notPaired
    case connecting
    case online
    case offline
    case revoked

    /// The status a node has when nothing is connected to it.
    init(resting pairing: PairingState) {
        switch pairing {
        case .unpaired, .pending: self = .notPaired
        case .paired: self = .offline
        case .revoked: self = .revoked
        }
    }

    var label: String {
        switch self {
        case .notPaired: "Not paired"
        case .connecting: "Connecting…"
        case .online: "Online"
        case .offline: "Offline"
        case .revoked: "Revoked"
        }
    }

    var tone: StatusTone {
        switch self {
        case .notPaired: .unknown
        case .connecting: .info
        case .online: .ok
        case .offline: .warn
        case .revoked: .danger
        }
    }

    var isTransitional: Bool { self == .connecting }
}

extension PairingState {
    var summary: String {
        switch self {
        case .unpaired: "Not paired"
        case .pending: "Waiting for approval"
        case .paired(_, _, let since): "Paired \(since.formatted(date: .abbreviated, time: .omitted))"
        case .revoked(let at): "Revoked \(at.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    var isPaired: Bool {
        if case .paired = self { true } else { false }
    }
}

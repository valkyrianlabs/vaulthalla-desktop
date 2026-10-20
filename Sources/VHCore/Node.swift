public import Foundation

/// A Vaulthalla deployment as Desktop knows it. The record is persisted (Application Support); nothing in it is
/// secret. The device's private key lives in the Keychain under `deviceKeyTag`, never here.
public struct Node: Identifiable, Codable, Hashable, Sendable {
    /// The daemon's install id, learned when pairing completes. Before that, a locally generated placeholder.
    public var id: NodeID
    /// What the operator calls it ("vh-storage", "Home lab"). Defaults to the name the daemon advertises.
    public var displayName: String
    public var endpoint: NodeEndpoint
    public var pairing: PairingState
    /// Whether the operator chose `displayName` (typed it, or renamed the node). When false, pairing replaces it with
    /// the name the daemon reports.
    public var isNamedByUser: Bool
    /// The daemon's install id, reported when pairing is approved. `id` stays the local one, because the device key
    /// in the Keychain is filed under it.
    public var serverNodeID: String?
    /// The server key the daemon announced it will switch to (docs/pairing.md §5), accepted as a second pin until
    /// the switch, then promoted.
    public var nextServerSPKISHA256: Data?

    public init(
        id: NodeID, displayName: String, endpoint: NodeEndpoint, pairing: PairingState = .unpaired,
        isNamedByUser: Bool = false, serverNodeID: String? = nil, nextServerSPKISHA256: Data? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.pairing = pairing
        self.isNamedByUser = isNamedByUser
        self.serverNodeID = serverNodeID
        self.nextServerSPKISHA256 = nextServerSPKISHA256
    }

    // Spelled out so records written before a member existed still load: the newer members are optional on disk.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, endpoint, pairing, isNamedByUser, serverNodeID, nextServerSPKISHA256
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(NodeID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        endpoint = try container.decode(NodeEndpoint.self, forKey: .endpoint)
        pairing = try container.decode(PairingState.self, forKey: .pairing)
        isNamedByUser = try container.decodeIfPresent(Bool.self, forKey: .isNamedByUser) ?? false
        serverNodeID = try container.decodeIfPresent(String.self, forKey: .serverNodeID)
        nextServerSPKISHA256 = try container.decodeIfPresent(Data.self, forKey: .nextServerSPKISHA256)
    }
}

public struct NodeID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func local() -> NodeID { NodeID(rawValue: "local-\(UUID().uuidString.lowercased())") }
    public var description: String { rawValue }
}

/// Where the daemon's device listener answers (docs/architecture.md §2, S1).
public struct NodeEndpoint: Codable, Hashable, Sendable, CustomStringConvertible {
    public static let defaultDevicePort: UInt16 = 36971

    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = NodeEndpoint.defaultDevicePort) {
        self.host = host
        self.port = port
    }

    /// Parses what an operator types: `host`, `host:port`, `[v6]:port`, or a URL whose scheme is ignored.
    public init?(parsing input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeEnd = text.range(of: "://") { text = String(text[schemeEnd.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if rest.isEmpty { self.init(host: host); return }
            guard rest.first == ":", let port = UInt16(rest.dropFirst()), port > 0 else { return nil }
            self.init(host: host, port: port)
            return
        }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            self.init(host: text)
        case 2:
            guard !parts[0].isEmpty, let port = UInt16(parts[1]), port > 0 else { return nil }
            self.init(host: String(parts[0]), port: port)
        default:
            // A bare IPv6 address without brackets carries no port.
            self.init(host: text)
        }
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public enum PairingState: Codable, Hashable, Sendable {
    case unpaired
    /// Waiting for approval on the node. `code` is the 6-digit SAS both sides show (docs/architecture.md §4).
    case pending(code: String)
    /// Mutual trust established: the daemon knows our SPKI, we pin the server's.
    case paired(serverSPKISHA256: Data, deviceID: String, since: Date)
    /// The node refused our certificate after we were paired.
    case revoked(at: Date)
}

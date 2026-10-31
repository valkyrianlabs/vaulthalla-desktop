public import Foundation
public import VHCore
public import VHTransport

/// A `vaulthalla://pair?node=<id>&spki=<hex>&endpoints=<host:port,…>` link from the web console's "Pair a device"
/// dialog (the server's transfer protocol §1.2).
///
/// Untrusted input: it may come from anywhere that can open a URL. It only saves typing and narrows trust on first
/// use: the Add Node sheet is prefilled with the best endpoint a probe verifies, and with `spki` present a pairing
/// connection presenting another key is refused. The six-digit code (docs/pairing.md) stays authoritative.
public struct PairLink: Hashable, Sendable {
    /// The server's install id (`device.pair.status` `node_id`), when the link names one. A hint only: pairing
    /// records the id the server reports.
    public var nodeID: String?
    /// The server key's SPKI SHA-256 the link names (32 bytes).
    public var serverSPKISHA256: Data?
    /// The device listener's endpoints, in the link's order, de-duplicated (at least one).
    public var endpoints: [NodeEndpoint]

    public static let scheme = "vaulthalla"
    /// Longer links are refused unread.
    public static let maxLength = 4096
    /// Endpoints past this many are ignored (the server advertises at most 32).
    public static let maxEndpoints = 32

    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        /// Not a `vaulthalla://pair` link.
        case notAPairLink
        case tooLong
        /// A parameter appears twice: ambiguous, so refused.
        case duplicateParameter(String)
        /// `spki` isn't 64 hex digits.
        case malformedKey
        /// `node` isn't an id Vaulthalla makes.
        case malformedNodeID
        /// No usable endpoint.
        case noEndpoints

        public var description: String {
            switch self {
            case .notAPairLink: "This isn't a Vaulthalla pairing link."
            case .tooLong: "This pairing link is too long to be one Vaulthalla made."
            case .duplicateParameter(let name): "This pairing link names \(name) twice."
            case .malformedKey: "This pairing link's server key isn't valid."
            case .malformedNodeID: "This pairing link's node id isn't valid."
            case .noEndpoints: "This pairing link has no address to connect to."
            }
        }
    }

    public init(nodeID: String?, serverSPKISHA256: Data?, endpoints: [NodeEndpoint]) {
        self.nodeID = nodeID
        self.serverSPKISHA256 = serverSPKISHA256
        self.endpoints = endpoints
    }

    /// Parses `url`. Unknown parameters are ignored; endpoints that don't parse are dropped.
    public init(url: URL) throws(Problem) {
        let text = url.absoluteString
        guard text.utf8.count <= Self.maxLength else { throw .tooLong }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme, components.host?.lowercased() == "pair",
              components.path.isEmpty || components.path == "/", components.user == nil, components.password == nil
        else { throw .notAPairLink }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard ["node", "spki", "endpoints"].contains(name) else { continue }
            guard values[name] == nil else { throw .duplicateParameter(name) }
            values[name] = item.value ?? ""
        }

        if let node = values["node"], !node.isEmpty {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard node.count <= 128, node.unicodeScalars.allSatisfy(allowed.contains) else { throw .malformedNodeID }
            nodeID = node
        } else {
            nodeID = nil
        }

        if let hex = values["spki"], !hex.isEmpty {
            guard let key = Self.hex32(hex) else { throw .malformedKey }
            serverSPKISHA256 = key
        } else {
            serverSPKISHA256 = nil
        }

        var seen: Set<String> = []
        var endpoints: [NodeEndpoint] = []
        for entry in (values["endpoints"] ?? "").split(separator: ",", omittingEmptySubsequences: true) {
            guard endpoints.count < Self.maxEndpoints, let endpoint = Self.endpoint(String(entry)) else { continue }
            guard seen.insert("\(endpoint.host.lowercased())|\(endpoint.port)").inserted else { continue }
            endpoints.append(endpoint)
        }
        guard !endpoints.isEmpty else { throw .noEndpoints }
        self.endpoints = endpoints
    }

    /// Parses a link's text.
    public init(string: String) throws(Problem) {
        guard string.utf8.count <= Self.maxLength else { throw .tooLong }
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .notAPairLink
        }
        try self.init(url: url)
    }

    /// `host:port`, `[v6]:port` or `host` (the default device port), with a host Desktop may connect to.
    static func endpoint(_ text: String) -> NodeEndpoint? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("@"),
              let parsed = NodeEndpoint(parsing: trimmed),
              let host = EndpointAdvertisement.host(parsed.host)
        else { return nil }
        // A bare IPv6 address must be bracketed when it carries a port; unbracketed it parses as a host alone.
        return NodeEndpoint(host: host, port: parsed.port)
    }

    static func hex32(_ text: String) -> Data? {
        let lower = text.lowercased()
        guard lower.count == 64, lower.allSatisfy(\.isHexDigit), lower.allSatisfy(\.isASCII) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = lower.startIndex
        while index < lower.endIndex {
            let next = lower.index(index, offsetBy: 2)
            guard let byte = UInt8(lower[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

extension PairLink {
    /// Probes the link's endpoints like a node's (the server's transfer protocol §2): a TLS handshake each, accepted
    /// when the server presents the link's key (any key when the link names none: the code decides then). No device
    /// identity exists yet, so the handshake stops once the server's key is checked.
    public func probe(selector: EndpointSelector = EndpointSelector(), prober: (any EndpointProbing)? = nil) async
        -> EndpointSelection
    {
        let prober = prober ?? TLSEndpointProber(identity: nil, pins: serverSPKISHA256.map { [$0] } ?? [])
        return await selector.select(EndpointCandidate.candidates(endpoints, source: .link), prober: prober)
    }

    /// The link's endpoints as a node record keeps advertised ones, so the node's first selections try them all.
    public var advertisedEndpoints: [AdvertisedEndpoint] {
        endpoints.map { AdvertisedEndpoint(host: $0.host, port: $0.port, source: "link") }
    }
}

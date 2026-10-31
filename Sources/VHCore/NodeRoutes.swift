public import Foundation

/// How directly an address reaches a node, best first (the server's transfer protocol §2: "Priority by the class of
/// the address actually connected to"). A host name is classified by what it resolved to, so split-horizon DNS works.
public enum EndpointClass: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    /// 127/8 and ::1: the daemon runs on this Mac.
    case loopback
    /// RFC 1918, IPv6 ULA (fc00::/7) and link-local: the same network.
    case lan
    /// 100.64/10 (CGNAT, Tailscale) and tunnel interfaces (`utun*`, `wg*`, `tailscale*`, `zt*`).
    case vpn
    /// Any other global address: across the internet, straight to the device listener.
    case wan
    /// A configured TLS passthrough (an SNI router on 443 in front of the device listener).
    case passthrough

    /// 0 (loopback) … 4 (passthrough); lower is better.
    public var rank: Int {
        switch self {
        case .loopback: 0
        case .lan: 1
        case .vpn: 2
        case .wan: 3
        case .passthrough: 4
        }
    }

    public static func < (lhs: EndpointClass, rhs: EndpointClass) -> Bool { lhs.rank < rhs.rank }

    /// What the status view calls it.
    public var displayName: String {
        switch self {
        case .loopback: "Localhost"
        case .lan: "LAN"
        case .vpn: "VPN"
        case .wan: "Direct WAN"
        case .passthrough: "Passthrough"
        }
    }
}

/// One address the node advertised for its device listener (`device.endpoints` `candidates`, transfer protocol §1.1),
/// as the app saved it in the node record. Nothing in it is trusted: the selector probes every candidate with the
/// pinned server key before using it.
public struct AdvertisedEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: UInt16
    /// The server's classification (`kind`); nil when it sent one this build doesn't know. Desktop classifies the
    /// address it actually connects to itself; this only orders probes before that is known.
    public var kind: EndpointClass?
    /// `interface`, `config` or `mdns` (kept as sent).
    public var source: String?
    /// The server's interface name, for diagnostics.
    public var interface: String?

    public init(host: String, port: UInt16, kind: EndpointClass? = nil, source: String? = nil, interface: String? = nil) {
        self.host = host
        self.port = port
        self.kind = kind
        self.source = source
        self.interface = interface
    }

    public var endpoint: NodeEndpoint { NodeEndpoint(host: host, port: port) }

    private enum CodingKeys: String, CodingKey { case host, port, kind, source, interface }

    /// Lenient: an unknown `kind` decodes as nil rather than failing the record.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(EndpointClass.init) }
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        interface = try? container.decodeIfPresent(String.self, forKey: .interface)
    }
}

/// The endpoint a Device session last came up on, so the next selection tries it first within its class.
public struct LastGoodEndpoint: Codable, Hashable, Sendable {
    public var endpoint: NodeEndpoint
    public var at: Date
    /// The class of the address that connection actually reached.
    public var transportClass: EndpointClass

    public init(endpoint: NodeEndpoint, at: Date, transportClass: EndpointClass) {
        self.endpoint = endpoint
        self.at = at
        self.transportClass = transportClass
    }
}

/// Decodes an array element by element, dropping elements that don't decode, so one malformed entry never makes a
/// node record (and with it the registry) unreadable.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skipped.self)
            }
        }
        self.elements = elements
    }

    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

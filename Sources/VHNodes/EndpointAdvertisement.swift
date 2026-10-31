public import Foundation
public import VHContract
public import VHCore
public import VHTransport

/// A node's `device.endpoints` answer (the server's transfer protocol §1.1), decoded by hand: the vendored contract
/// doesn't type the command yet (`WsCapability.awaitingContract`). Untrusted input: every candidate is validated and
/// the list is capped, and nothing here is used before the selector proved the pinned key at that address.
public struct EndpointAdvertisement: Hashable, Sendable {
    /// The server's install id (`device.pair.status` `node_id`); an answer naming another node is ignored.
    public var nodeID: String?
    /// The device listener's port.
    public var port: UInt16?
    /// Whether the listener accepts remote connections (false: loopback only).
    public var remote: Bool?
    public var listening: Bool?
    public var generatedAt: Date?
    public var candidates: [AdvertisedEndpoint]

    /// The most candidates kept (the server caps its list at 32 too).
    public static let maxCandidates = 32

    public init(nodeID: String? = nil, port: UInt16? = nil, remote: Bool? = nil, listening: Bool? = nil,
                generatedAt: Date? = nil, candidates: [AdvertisedEndpoint]) {
        self.nodeID = nodeID
        self.port = port
        self.remote = remote
        self.listening = listening
        self.generatedAt = generatedAt
        self.candidates = candidates
    }

    /// Reads the answer's JSON. Malformed members are dropped (the candidate, or the member), never fatal.
    public init(json: JSONValue) {
        nodeID = json["node_id"]?.stringValue.flatMap { $0.isEmpty || $0.count > 128 ? nil : $0 }
        port = json["port"].flatMap(Self.port)
        remote = json["remote"]?.boolValue
        listening = json["listening"]?.boolValue
        generatedAt = json["generated_at"]?.integerValue.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        var seen: Set<String> = []
        var kept: [AdvertisedEndpoint] = []
        for item in json["candidates"]?.arrayValue ?? [] {
            guard kept.count < Self.maxCandidates,
                  let host = item["host"]?.stringValue.flatMap(Self.host), let port = item["port"].flatMap(Self.port)
            else { continue }
            guard seen.insert("\(host.lowercased())|\(port)").inserted else { continue }
            kept.append(AdvertisedEndpoint(
                host: host, port: port,
                kind: item["kind"]?.stringValue.flatMap(EndpointClass.init(rawValue:)),
                source: item["source"]?.stringValue.flatMap { Self.token($0) },
                interface: item["interface"]?.stringValue.flatMap { Self.token($0) }))
        }
        candidates = kept
    }

    /// A host Desktop may connect to: a DNS name or an IP literal, nothing that would make a different URL.
    static func host(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.utf8.count <= 253 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_")
        guard host.unicodeScalars.allSatisfy(allowed.contains), !host.hasPrefix("-"), !host.hasPrefix(".") else {
            return nil
        }
        // Colons only in an IPv6 literal.
        if host.contains(":"), EndpointClassifier.classify(address: host) == nil { return nil }
        return host
    }

    static func port(_ value: JSONValue) -> UInt16? {
        guard let number = value.integerValue, (1...65535).contains(number) else { return nil }
        return UInt16(number)
    }

    /// Short diagnostic tokens (`interface`, `source`): printable ASCII, at most 64 characters.
    static func token(_ text: String) -> String? {
        guard !text.isEmpty, text.count <= 64, text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 })
        else { return nil }
        return text
    }
}

/// Where a session gets a node's advertised endpoints once it is a Device session. The real one asks
/// `device.endpoints` on the session's own connection; tests stand in their own.
public protocol EndpointAdvertisementSource: Sendable {
    func advertisement(on client: WsClient, timeout: Duration) async throws(WsError) -> EndpointAdvertisement
}

/// `device.endpoints {}` on the Device session (raw: the vendored contract doesn't have the command yet).
public struct WsEndpointAdvertisementSource: EndpointAdvertisementSource {
    public static let command = "device.endpoints"

    public init() {}

    public func advertisement(on client: WsClient, timeout: Duration) async throws(WsError) -> EndpointAdvertisement {
        EndpointAdvertisement(json: try await client.send(command: Self.command, payload: .object([:]),
                                                           timeout: timeout))
    }
}

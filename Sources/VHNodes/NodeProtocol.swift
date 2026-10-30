import Foundation
public import VHContract
public import VHTransport

/// What `meta.hello` settled with one node (docs/architecture.md §3, "Protocol negotiation"): the protocol version
/// both sides speak, the daemon's product and release, its protocol range, the capabilities and ws commands it has,
/// and the contract it was built from.
///
/// Three outcomes, in ``state``:
/// - **negotiated:** the daemon answered `meta.hello` with a version in ``WsProtocol/supported``. ``supports(command:)``
///   and ``supports(capability:)`` answer yes or no from its lists.
/// - **legacy:** the daemon predates `meta.hello` (≤ 1.18.0) and refused it as an unknown command. Protocol 1 is
///   assumed and nothing else is known: every support check is ``ProtocolSupport/unknown``, and feature code falls
///   back to trying the command and reading "Unknown command" (`WsError.isUnknownCommand`).
/// - **incompatible:** the ranges don't overlap (`protocol_unsupported`, or a negotiated version outside this build's
///   range). The session stays connected so the node shows what it runs, but feature calls are refused here
///   (`WsError.protocolUnsupported`) without being sent; every support check is ``ProtocolSupport/no``.
///
/// A session renegotiates on every connect, so an upgraded node is picked up on the next reconnect.
public struct NodeProtocol: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case negotiated
        case legacy
        /// `reason` says which side has to move (``ProtocolMismatch/Side``).
        case incompatible(serverMin: Int?, serverMax: Int?, serverVersion: String?, reason: ProtocolMismatch.Side)
    }

    /// The contract the daemon was built from, as `meta.hello` reports it (the same four values as
    /// `meta.contract.get`).
    public struct ContractIdentity: Hashable, Sendable {
        public var contractVersion: Int
        public var contractHash: String
        public var wsHash: String
        public var modelsHash: String

        public init(contractVersion: Int, contractHash: String, wsHash: String, modelsHash: String) {
            self.contractVersion = contractVersion
            self.contractHash = contractHash
            self.wsHash = wsHash
            self.modelsHash = modelsHash
        }

        /// Whether the daemon's command book is the one this build was generated from.
        public var matchesThisBuild: Bool { wsHash == WsContract.wsHash }
    }

    public var state: State
    /// The protocol both sides speak: the negotiated one, ``WsProtocol/legacyVersion`` on a legacy node, nil when
    /// incompatible.
    public var version: Int?
    /// The daemon's product name ("vaulthalla"); nil on a legacy node.
    public var serverName: String?
    /// The daemon's release ("1.19.0"); nil on a legacy node (and when an incompatible one didn't say).
    public var serverVersion: String?
    /// The protocols the daemon speaks; nil on a legacy node.
    public var serverRange: ClosedRange<Int>?
    /// The capabilities the daemon announced; nil when unknown (legacy).
    public var capabilities: Set<String>?
    /// The ws commands the daemon has; nil when unknown (legacy).
    public var commands: Set<String>?
    public var contract: ContractIdentity?

    public init(state: State, version: Int?, serverName: String? = nil, serverVersion: String? = nil,
                serverRange: ClosedRange<Int>? = nil, capabilities: Set<String>? = nil, commands: Set<String>? = nil,
                contract: ContractIdentity? = nil) {
        self.state = state
        self.version = version
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.serverRange = serverRange
        self.capabilities = capabilities
        self.commands = commands
        self.contract = contract
    }

    /// A daemon without `meta.hello`.
    public static let legacy = NodeProtocol(state: .legacy, version: WsProtocol.legacyVersion)

    // MARK: Support checks

    /// Whether the daemon has the ws command: from the hello's `commands`; unknown on a legacy node; no on an
    /// incompatible one (nothing is sent to it).
    public func supports(command: String) -> ProtocolSupport {
        switch state {
        case .incompatible: .no
        case .legacy: .unknown
        case .negotiated: ProtocolSupport(commands.map { $0.contains(command) })
        }
    }

    public func supports(command: WsCommand) -> ProtocolSupport {
        supports(command: command.rawValue)
    }

    /// Whether the daemon announced the capability; unknown on a legacy node; no on an incompatible one.
    public func supports(capability: WsCapability) -> ProtocolSupport {
        switch state {
        case .incompatible: .no
        case .legacy: .unknown
        case .negotiated: ProtocolSupport(capabilities.map { $0.contains(capability.rawValue) })
        }
    }

    // MARK: Outcome

    public var isLegacy: Bool { state == .legacy }

    /// Why feature calls are refused, when the node is incompatible.
    public var mismatch: ProtocolMismatch? {
        guard case .incompatible(let low, let high, let release, _) = state else { return nil }
        return ProtocolMismatch(serverMin: low, serverMax: high, serverVersion: release)
    }

    /// "Vaulthalla 1.19.0 · protocol 1"; "Vaulthalla 1.18 or earlier" for a legacy node; "Vaulthalla 2.0.0 ·
    /// protocol 2–3" for an incompatible one (the message says the rest).
    public var productLabel: String {
        let product = Self.product(serverName)
        switch state {
        case .legacy:
            return "\(product) \(WsProtocol.newestLegacyServer) or earlier"
        case .negotiated:
            let release = serverVersion.map { "\(product) \($0)" } ?? product
            return version.map { "\(release) · protocol \($0)" } ?? release
        case .incompatible(let low, let high, let release, _):
            let name = release.map { "\(product) \($0)" } ?? product
            switch (low, high) {
            case (let low?, let high?): return "\(name) · protocol \(low == high ? "\(low)" : "\(low)–\(high)")"
            default: return name
            }
        }
    }

    private static func product(_ name: String?) -> String {
        guard let name, !name.isEmpty, name.lowercased() != "vaulthalla" else { return "Vaulthalla" }
        return name
    }

    /// The outcome of a `meta.hello` exchange. nil when it decided nothing (no answer yet, a lost connection, a
    /// refusal other than "unknown command" or `protocol_unsupported`): support stays unknown until the next connect.
    public static func outcome(of result: Result<HelloResponse, WsError>) -> NodeProtocol? {
        switch result {
        case .success(let hello):
            return negotiated(hello)
        case .failure(.protocolUnsupported(let mismatch)):
            return NodeProtocol(
                state: .incompatible(serverMin: mismatch.serverMin, serverMax: mismatch.serverMax,
                                     serverVersion: mismatch.serverVersion, reason: mismatch.side),
                version: nil, serverVersion: mismatch.serverVersion,
                serverRange: mismatch.serverMin.flatMap { low in mismatch.serverMax.map { low...max(low, $0) } })
        case .failure(let error) where error.isUnknownCommand:
            return .legacy
        case .failure:
            return nil
        }
    }

    /// A hello answer: negotiated when its version is one this build speaks, incompatible otherwise (a daemon that
    /// picked a version outside the range this build sent).
    static func negotiated(_ hello: HelloResponse) -> NodeProtocol {
        let (version, low, high) = (Int(clamping: hello.protocol.version), Int(clamping: hello.protocol.min),
                                    Int(clamping: hello.protocol.max))
        let range = low...max(low, high)
        let contract = ContractIdentity(contractVersion: Int(clamping: hello.contract.contractVersion),
                                        contractHash: hello.contract.contractHash, wsHash: hello.contract.wsHash,
                                        modelsHash: hello.contract.modelsHash)
        guard WsProtocol.supported.contains(version) else {
            let mismatch = ProtocolMismatch(serverMin: low, serverMax: high, serverVersion: hello.server.version)
            return NodeProtocol(
                state: .incompatible(serverMin: mismatch.serverMin, serverMax: mismatch.serverMax,
                                     serverVersion: mismatch.serverVersion, reason: mismatch.side),
                version: nil, serverName: hello.server.name, serverVersion: hello.server.version, serverRange: range,
                capabilities: Set(hello.capabilities), commands: Set(hello.commands), contract: contract)
        }
        return NodeProtocol(state: .negotiated, version: version, serverName: hello.server.name,
                            serverVersion: hello.server.version, serverRange: range,
                            capabilities: Set(hello.capabilities), commands: Set(hello.commands), contract: contract)
    }
}

// MARK: - meta.hello

/// `meta.hello` (`Ws.Meta.Hello`, any session): this client's name, release and protocol range in; the negotiated
/// version, the daemon's release, range, capabilities, commands and contract out. No overlap is refused with
/// `data.code` "protocol_unsupported" (`WsError.protocolUnsupported`); a daemon that predates it (≤ 1.18.0) answers
/// "Unknown command" without a code.
public typealias HelloResponse = Ws.Meta.Hello.Response

extension Ws.Meta.Hello {
    /// The release this process reports: the bundle's `CFBundleShortVersionString`, or "0" when it has none (tests,
    /// `swift run`).
    public static var clientVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }
}

extension Ws.Meta.Hello.Payload {
    /// This build: ``WsProtocol/clientName``, `clientVersion` (`CFBundleShortVersionString`) and
    /// ``WsProtocol/supported``.
    public init(thisBuild clientVersion: String) {
        self.init(client: Client(name: WsProtocol.clientName, version: clientVersion),
                  protocol: ProtocolValue(min: Int64(WsProtocol.minimum), max: Int64(WsProtocol.maximum)))
    }
}

extension WsClient {
    /// Sends `meta.hello` for this build and settles the outcome (``NodeProtocol/outcome(of:)``).
    public func negotiate(clientVersion: String = Ws.Meta.Hello.clientVersion,
                          timeout: Duration = WsClient.defaultTimeout) async -> NodeProtocol? {
        do throws(WsError) {
            let hello = try await send(Ws.Meta.Hello.self, payload: .init(thisBuild: clientVersion), timeout: timeout)
            return NodeProtocol.outcome(of: .success(hello))
        } catch {
            return NodeProtocol.outcome(of: .failure(error))
        }
    }
}

public import Foundation
public import VHCore
public import VHIdentity
public import VHTransport
import Network
import Synchronization

/// The route a session's connection takes to its node, as the status view shows it: the endpoint, the class of the
/// address reached, the handshake RTT, which server key it proved, and the selection that chose it (every
/// candidate's outcome). Nothing in it is secret: no keys, no session material.
public struct NodeRoute: Hashable, Sendable {
    /// Which pin the server presented.
    public enum VerifiedKey: Hashable, Sendable {
        /// The key this Mac paired with (or last promoted).
        case current
        /// The next key the node announced (docs/pairing.md §5): accepted until it is promoted.
        case next
        /// Not proven by a probe (the selector found no verified route and the session fell back to the configured
        /// address, which the connection itself pins).
        case unverified
    }

    /// The endpoint the connection uses.
    public var endpoint: NodeEndpoint
    public var transportClass: EndpointClass
    /// The round trip of the probe's handshake.
    public var rtt: Duration?
    /// The address actually connected to, and the local interface.
    public var remoteAddress: String?
    public var interfaceName: String?
    public var verifiedKey: VerifiedKey
    /// Whether the connection is up on it (false while connecting or reconnecting).
    public var isConnected: Bool
    /// The selection behind it; nil before the first one.
    public var selection: EndpointSelection?

    public init(endpoint: NodeEndpoint, transportClass: EndpointClass, rtt: Duration? = nil, remoteAddress: String? = nil,
                interfaceName: String? = nil, verifiedKey: VerifiedKey, isConnected: Bool,
                selection: EndpointSelection? = nil) {
        self.endpoint = endpoint
        self.transportClass = transportClass
        self.rtt = rtt
        self.remoteAddress = remoteAddress
        self.interfaceName = interfaceName
        self.verifiedKey = verifiedKey
        self.isConnected = isConnected
        self.selection = selection
    }

    /// No candidate proved the pin: the session connects to the configured endpoint and lets the connection decide.
    public var isFallback: Bool { verifiedKey == .unverified }
}

extension TransferEndpointClass {
    /// The class transfers to `endpoint` are tuned for: the selected route's (what its host resolved to and the
    /// interface it leaves by) when the route is that endpoint, else the literal-address heuristic of
    /// ``init(host:)`` (a host name without a route stays `unknown`).
    public init(endpoint: NodeEndpoint, route: NodeRoute?) {
        if let route, route.endpoint == endpoint {
            self.init(route.transportClass)
        } else {
            self.init(host: endpoint.host)
        }
    }
}

/// The endpoint-selection knobs a session or a consumer uses: the selector's timing, the schedule, how a probe is
/// made, Bonjour (the last source) and the network path changes that trigger a new selection. Tests replace the
/// prober, Bonjour and the path changes.
public struct RouteSettings: Sendable {
    public typealias ProberFactory = @Sendable (_ identity: DeviceIdentity?, _ pins: [Data]) -> any EndpointProbing
    public typealias BonjourLookup = @Sendable (_ serverNodeID: String, _ within: Duration) async -> [NodeEndpoint]

    public var selector = EndpointSelector.Configuration()
    public var schedule = RouteSchedule()
    public var prober: ProberFactory = { identity, pins in TLSEndpointProber(identity: identity?.secIdentity, pins: pins) }
    /// nil: no Bonjour.
    public var bonjour: BonjourLookup? = { nodeID, within in
        await BonjourServiceBrowser.endpoints(forNode: nodeID, within: within)
    }
    /// A stream that yields whenever the network path changes (not for the current path); nil: none.
    public var pathChanges: (@Sendable () -> AsyncStream<Void>)? = { PathChanges.stream() }

    public init() {}

    /// Probes the candidates for `node` with `identity` and the node's pins (the pin given, then the announced next).
    public func select(_ node: Node, identity: DeviceIdentity?, pin: Data) async -> EndpointSelection {
        let pins = [pin, node.nextServerSPKISHA256].compactMap(\.self).filter { !$0.isEmpty }
        let unique = pins.reduce(into: [Data]()) { if !$0.contains($1) { $0.append($1) } }
        let lookup = bonjour.flatMap { lookup in
            node.serverNodeID.map { id in { @Sendable (within: Duration) in await lookup(id, within) } }
        }
        return await EndpointSelector(configuration: selector).select(
            EndpointCandidate.candidates(for: node), prober: prober(identity, unique), bonjour: lookup)
    }
}

/// Network path changes as a stream: yields on every satisfied path that differs from the previous one (the first
/// update, the current path, is not a change).
public enum PathChanges {
    public static func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let monitor = NWPathMonitor()
        let last = Mutex<NWPath?>(nil)
        monitor.pathUpdateHandler = { path in
            let changed = last.withLock { previous in
                defer { previous = path }
                guard let previous else { return false }
                return path.status == .satisfied && path != previous
            }
            if changed { continuation.yield() }
        }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "sh.vaulthalla.path"))
        return stream
    }
}

/// Endpoint selection for processes without a session of their own (the MCP bridge): one selection per node, reused
/// while it is fresh (``maximumAge``), never run more often than the schedule allows, and dropped after a failure.
/// Read-only: it never writes the registry.
public actor RouteCache {
    public var maximumAge: Duration
    private let settings: RouteSettings
    private var entries: [NodeID: (selection: EndpointSelection, at: ContinuousClock.Instant)] = [:]
    private var schedules: [NodeID: RouteSchedule] = [:]
    private var inFlight: [NodeID: Task<EndpointSelection, Never>] = [:]

    public init(settings: RouteSettings = RouteSettings(), maximumAge: Duration = .seconds(300)) {
        self.settings = settings
        self.maximumAge = maximumAge
    }

    /// The endpoint to reach `credentials.node` on now: the chosen one, or the configured endpoint when nothing
    /// proved the pin (the connection then decides, as before).
    public func endpoint(for credentials: NodeCredentials) async -> NodeEndpoint {
        await selection(for: credentials).chosen?.candidate.endpoint ?? credentials.node.endpoint
    }

    /// The node's selection, fresh or reused.
    public func selection(for credentials: NodeCredentials) async -> EndpointSelection {
        let id = credentials.node.id
        let clock = ContinuousClock()
        if let entry = entries[id], entry.selection.chosen != nil, clock.now < entry.at + maximumAge {
            return entry.selection
        }
        if let running = inFlight[id] { return await running.value }
        var schedule = schedules[id] ?? settings.schedule
        if let earliest = schedule.earliest(for: .connect, activeClass: nil, now: clock.now), earliest > clock.now {
            try? await clock.sleep(until: earliest)
        }
        let settings = settings
        let task = Task { await settings.select(credentials.node, identity: credentials.identity,
                                                pin: credentials.serverPin) }
        inFlight[id] = task
        let selection = await task.value
        inFlight[id] = nil
        schedule.recordSelection(at: clock.now, verified: selection.chosen != nil)
        schedules[id] = schedule
        entries[id] = (selection, clock.now)
        return selection
    }

    /// Forgets the node's selection (a connection failure): the next call selects again.
    public func invalidate(_ id: NodeID) {
        entries[id] = nil
    }
}

/// What "Test connection" in the status view found. The default (``ConnectionTests/route``) re-runs the endpoint
/// selection; a calibration over the device listener's `/transfer/*` lanes (`device.lanes.transfer`) adds measured
/// throughput.
public struct ConnectionTestResult: Hashable, Sendable {
    /// The fresh selection (every candidate's outcome).
    public var selection: EndpointSelection?
    /// The route afterwards.
    public var route: NodeRoute?
    /// Measured bytes per second, when the test calibrated.
    public var uploadBytesPerSecond: Double?
    public var downloadBytesPerSecond: Double?
    /// The calibration behind them (RTT, the part size and concurrency uploads would start with), when it ran.
    public var calibration: TransferCalibrator.Result?
    /// One plain sentence about the outcome, when the test has one to add.
    public var note: String?
    public var finishedAt: Date

    public init(selection: EndpointSelection? = nil, route: NodeRoute? = nil, uploadBytesPerSecond: Double? = nil,
                downloadBytesPerSecond: Double? = nil, calibration: TransferCalibrator.Result? = nil,
                note: String? = nil, finishedAt: Date = .now) {
        self.selection = selection
        self.route = route
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.calibration = calibration
        self.note = note
        self.finishedAt = finishedAt
    }
}

/// Runs "Test connection" against a node's session.
public typealias ConnectionTest = @Sendable (NodeSession) async -> ConnectionTestResult

public enum ConnectionTests {
    /// Selects the route again (``NodeSession/testRoute()``: every candidate probed, the connection moved if a better
    /// route answers) and reports it. Safe on any node: it sends nothing but TLS handshakes.
    public static let route: ConnectionTest = { session in
        let selection = await session.testRoute()
        return ConnectionTestResult(selection: selection, route: await session.route,
                                    note: selection == nil ? "The node's session isn't connected yet." : nil)
    }

    /// ``route``, then, where the node announces `device.lanes.transfer`, `calibrate` (the node's lanes'
    /// `testConnection()`: `/transfer/probe`, `/sink`, `/source`, nothing written on the node) over the route it
    /// settled on. The measured throughput fills the result; a calibration that fails leaves the route's result
    /// standing with the reason as its note. A node without the capability (or a legacy one) gets the route test only.
    public static func calibrating(
        _ calibrate: @escaping @Sendable (NodeSession) async throws(TransferError) -> TransferCalibrator.Result
    ) -> ConnectionTest {
        { session in
            var result = await route(session)
            guard result.selection != nil, await session.supports(capability: .transferLane) == .yes else {
                return result
            }
            do throws(TransferError) {
                let measured = try await calibrate(session)
                result.uploadBytesPerSecond = measured.uploadBytesPerSecond
                result.downloadBytesPerSecond = measured.downloadBytesPerSecond
                result.calibration = measured
                result.note = note(for: measured)
            } catch {
                result.note = "The route works, but throughput couldn't be measured: \(error.message)"
            }
            result.finishedAt = .now
            return result
        }
    }

    /// "Uploads would start with 64 MiB parts, 2 at a time (RTT 1.2 ms)."
    static func note(for measured: TransferCalibrator.Result) -> String {
        let part = String(format: "%.0f MiB", Double(measured.suggestedPartBytes) / Double(1 << 20))
        var text = "Uploads would start with \(part) parts, \(measured.suggestedConcurrency) at a time"
        if let rtt = measured.rtt { text += String(format: " (RTT %.1f ms)", rtt * 1000) }
        return text + "."
    }
}

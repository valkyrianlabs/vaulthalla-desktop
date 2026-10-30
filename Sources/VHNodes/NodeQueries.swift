public import Foundation
public import Observation
public import VHContract
public import VHTransport

/// One node's server data for the views: the TanStack Query idea, minimal (docs/architecture.md §3).
///
/// - A read is a ``NodeQuery``, keyed by command and payload: asking for the same key again returns the same object,
///   so every view showing it shares one value and one in-flight fetch.
/// - Stale-while-revalidate: a refresh keeps the last value on screen; a failed refresh is reported next to it.
/// - Polling runs only while a view observes the query (``NodeQuery/observe(polling:)``) and ``isActive`` is true.
/// - Mutations (``perform(_:_:invalidating:accepting:)``) invalidate related reads afterwards and turn a
///   `needsConfirmation` refusal into a ``ConfirmationRequest`` the view presents before resending.
///
/// Main-actor isolated: it is view state. Fetches run as tasks that outlive the view that started them, so a value
/// that arrives after a view went away still lands in the cache.
@MainActor
@Observable
public final class NodeQueries {
    public struct Configuration: Sendable {
        /// A value older than this is fetched again when a view appears or the app becomes active.
        public var staleAfter: Duration = .seconds(15)
        /// An unobserved query is forgotten this long after its last view went away.
        public var cacheTime: Duration = .seconds(300)
        /// Unobserved queries beyond this many are forgotten, least recently observed first.
        public var capacity = 64

        public init() {}
    }

    public nonisolated let configuration: Configuration
    @ObservationIgnored let transport: any NodeTransport

    /// Whether polling may run: the app is active and its window visible. The app sets it; tests flip it.
    public var isActive = true {
        didSet {
            guard isActive != oldValue else { return }
            for entry in entries.values { entry.activityChanged() }
        }
    }

    /// Whether the node's session is connected, as the app last reported it (``connectionChanged(online:)``).
    public private(set) var isConnected = true
    /// Set once any query has an answer: a view can keep showing (stale) data through a reconnect.
    public private(set) var hasAnswered = false
    /// What the node's session negotiated, as the app last reported it (``protocolChanged(_:)``); nil before any
    /// negotiation settled something.
    public private(set) var nodeProtocol: NodeProtocol?

    @ObservationIgnored private var entries: [QueryKey: any QueryEntry] = [:]

    public init(transport: any NodeTransport, configuration: Configuration = Configuration()) {
        self.transport = transport
        self.configuration = configuration
    }

    // MARK: - Reads

    /// The query for `request` with `payload`, shared by everyone asking for the same key. Asking doesn't fetch;
    /// ``NodeQuery/observe(polling:)`` (a view's `.task`) or ``NodeQuery/refresh()`` does.
    public func query<R: WsRequest>(_ request: R.Type, _ payload: R.Payload) -> NodeQuery<R> {
        let key = QueryKey(R.command, payload)
        if let existing = entries[key] as? NodeQuery<R> { return existing }
        prune()
        let made = NodeQuery<R>(key: key, payload: payload, store: self)
        entries[key] = made
        return made
    }

    public func query<R: WsRequest>(_ request: R.Type) -> NodeQuery<R> where R.Payload == WsNoPayload {
        query(request, WsNoPayload())
    }

    /// Marks every query of a command under `prefix` stale (`"storage.vault"` covers `storage.vault.list` and
    /// `storage.vault.get`, not `storage.vaults`). Observed ones fetch again now; the others on their next view.
    public func invalidate(prefix: String) {
        for (key, entry) in entries where key.command.rawValue == prefix || key.command.rawValue.hasPrefix(prefix + ".") {
            entry.invalidate()
        }
    }

    public func invalidate(_ commands: WsCommand...) {
        for (key, entry) in entries where commands.contains(key.command) { entry.invalidate() }
    }

    /// Refreshes every observed query (⌘R).
    public func refreshObserved() {
        for entry in entries.values where entry.isObserved { entry.refetch() }
    }

    /// The app reports the session's connection. Coming back online refetches what views show.
    public func connectionChanged(online: Bool) {
        guard online != isConnected else { return }
        isConnected = online
        guard online else { return }
        for entry in entries.values where entry.isObserved { entry.refetch() }
    }

    /// The app reports what the session's `meta.hello` settled. Views read it through ``supports(command:)`` and
    /// ``supports(capability:)`` (observed: a section switches paths, such as to a legacy list, when it changes).
    public func protocolChanged(_ settled: NodeProtocol?) {
        guard settled != nodeProtocol else { return }
        nodeProtocol = settled
    }

    /// Whether the node has the ws command: yes or no once negotiated, unknown on a legacy node or before a
    /// negotiation (try it, and read a refusal with `WsError.isUnknownCommand`).
    public func supports(command: WsCommand) -> ProtocolSupport {
        nodeProtocol?.supports(command: command) ?? .unknown
    }

    /// Whether the node announced the capability; unknown on a legacy node or before a negotiation.
    public func supports(capability: WsCapability) -> ProtocolSupport {
        nodeProtocol?.supports(capability: capability) ?? .unknown
    }

    /// Whether the node runs a Vaulthalla this build can't speak to: its feature calls are refused unsent.
    public var incompatibility: ProtocolMismatch? { nodeProtocol?.mismatch }

    func answered() {
        if !hasAnswered { hasAnswered = true }
    }

    /// Drops unobserved, idle queries past ``Configuration/cacheTime``, then the oldest beyond the capacity.
    private func prune() {
        let now = ContinuousClock.now
        let idle = entries.filter { !$0.value.isObserved && !$0.value.isFetching }
        for (key, entry) in idle where now - entry.lastObserved > configuration.cacheTime {
            entries[key] = nil
        }
        guard entries.count >= configuration.capacity else { return }
        let oldest = entries.filter { !$0.value.isObserved && !$0.value.isFetching }
            .sorted { $0.value.lastObserved < $1.value.lastObserved }
        for (key, _) in oldest.prefix(entries.count - configuration.capacity + 1) { entries[key] = nil }
    }

    /// Queries held (tests).
    var cachedCount: Int { entries.count }

    // MARK: - Mutations

    /// Runs a mutation. A refusal asking for a confirmation in `accepting` (one the person already gave in the view,
    /// such as a typed vault name) is resent with that acceptance; any other comes back as
    /// ``MutationResult/needsConfirmation(_:)`` to ask. After success, the queries under `invalidating` are stale.
    public func perform<R: WsRequest>(
        _ request: R.Type, _ payload: R.Payload, invalidating prefixes: [String] = [], accepting: Set<String> = []
    ) async -> MutationResult<R> where R.Payload: Decodable {
        var payload = payload
        var applied: Set<String> = []
        while true {
            do {
                let response = try await transport.send(R.self, payload: payload)
                for prefix in prefixes { invalidate(prefix: prefix) }
                return .success(response)
            } catch {
                guard case .needsConfirmation(let code, let message) = error else { return .failure(error) }
                guard accepting.contains(code) else {
                    return .needsConfirmation(ConfirmationRequest(
                        code: code, message: message, confirmation: R.command.confirmation(code), payload: payload,
                        accepted: accepting, invalidating: prefixes))
                }
                // Accepted, and the daemon asks again: don't loop.
                guard !applied.contains(code) else { return .failure(error) }
                do {
                    payload = try R.payload(payload, accepting: code)
                } catch {
                    return .failure(.error("This version of Vaulthalla can't confirm “\(message)” (\(code))."))
                }
                applied.insert(code)
            }
        }
    }

    /// Resends a mutation once the person accepted `request` (the payload it was refused with, plus every
    /// acceptance given so far).
    public func accept<R: WsRequest>(_ request: ConfirmationRequest<R>) async -> MutationResult<R>
    where R.Payload: Decodable {
        await perform(R.self, request.payload, invalidating: request.invalidating,
                      accepting: request.accepted.union([request.code]))
    }
}

// MARK: - Query

/// Where a query stands. A refresh of a loaded value stays `.loaded` (stale-while-revalidate); its failure is
/// ``NodeQuery/refreshError``.
public enum QueryState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value, at: Date)
    case failed(WsError)
}

/// One cached read of a node (``NodeQueries/query(_:_:)``).
@MainActor
@Observable
public final class NodeQuery<R: WsRequest> {
    public nonisolated let payload: R.Payload
    public private(set) var state: QueryState<R.Response> = .idle
    /// The latest refresh's failure while an earlier value is still shown; nil once a refresh succeeds.
    public private(set) var refreshError: WsError?
    public private(set) var isFetching = false

    @ObservationIgnored nonisolated let key: QueryKey
    @ObservationIgnored private weak var store: NodeQueries?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var invalidated = false
    @ObservationIgnored private var observers: [UUID: Duration?] = [:]
    @ObservationIgnored private var poller: (task: Task<Void, Never>, interval: Duration)?
    @ObservationIgnored private(set) var lastObserved = ContinuousClock.now
    /// Monotonic time of the last answer, for staleness (`state` carries the wall-clock time for display).
    @ObservationIgnored private var answeredAt: ContinuousClock.Instant?

    init(key: QueryKey, payload: R.Payload, store: NodeQueries) {
        self.key = key
        self.payload = payload
        self.store = store
    }

    public var value: R.Response? {
        if case .loaded(let value, _) = state { return value }
        return nil
    }

    /// When the shown value was fetched.
    public var updatedAt: Date? {
        if case .loaded(_, let at) = state { return at }
        return nil
    }

    /// The failure to show: the query's own, or the latest refresh's next to an older value.
    public var error: WsError? {
        if case .failed(let error) = state { return error }
        return refreshError
    }

    public var isStale: Bool {
        guard let answeredAt, !invalidated, let store else { return true }
        return ContinuousClock.now - answeredAt >= store.configuration.staleAfter
    }

    /// Fetches now, or joins the fetch already under way. Returns when it has settled.
    public func refresh() async {
        if let inflight { return await inflight.value }
        let task = Task { await self.load() }
        inflight = task
        await task.value
    }

    /// Fetches unless the value is fresh.
    public func refreshIfStale() async {
        guard isStale || isFetching else { return }
        await refresh()
    }

    /// Marks the value stale; refetches now if a view shows it.
    public func invalidate() {
        invalidated = true
        if isObserved { refetch() }
    }

    /// Keeps the query fresh while the calling task runs (a view's `.task`): fetches when stale, then polls every
    /// `interval` while the app is active (the shortest interval any observer asked for). Returns when cancelled.
    public func observe(polling interval: Duration? = nil) async {
        let id = UUID()
        observers[id] = .some(interval)
        updatePolling()
        defer {
            observers[id] = nil
            lastObserved = .now
            updatePolling()
        }
        await refreshIfStale()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    // MARK: Fetching

    private func load() async {
        defer { inflight = nil }
        guard let store else { return }
        isFetching = true
        defer { isFetching = false }
        switch state {
        case .idle, .failed: state = .loading
        case .loading, .loaded: break
        }
        do {
            let value = try await store.transport.send(R.self, payload: payload)
            state = .loaded(value, at: .now)
            answeredAt = .now
            refreshError = nil
            invalidated = false
            store.answered()
        } catch {
            switch (error, state) {
            case (.cancelled, .loading): state = .idle
            case (.cancelled, _): break
            case (_, .loaded): refreshError = error
            default: state = .failed(error)
            }
        }
    }

    // MARK: Polling

    private var pollInterval: Duration? {
        observers.values.compactMap { $0 }.min()
    }

    /// Starts, restarts or stops the poller to match the observers and the app's activity.
    private func updatePolling() {
        let wanted = (store?.isActive ?? false) && !observers.isEmpty ? pollInterval : nil
        if poller?.interval == wanted { return }
        poller?.task.cancel()
        poller = nil
        guard let wanted else { return }
        // A paused poller resumes on the old schedule: fetch at once when the value is older than the interval.
        let age = answeredAt.map { ContinuousClock.now - $0 } ?? wanted
        let first = max(.zero, wanted - age)
        let task = Task { [weak self] in
            var delay = first
            while !Task.isCancelled {
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                }
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
                delay = wanted
            }
        }
        poller = (task, wanted)
    }
}

/// The type-erased side of a query the store manages.
@MainActor
protocol QueryEntry: AnyObject {
    var isObserved: Bool { get }
    var isFetching: Bool { get }
    var lastObserved: ContinuousClock.Instant { get }
    func invalidate()
    func refetch()
    func activityChanged()
}

extension NodeQuery: QueryEntry {
    var isObserved: Bool { !observers.isEmpty }

    func refetch() {
        Task { await refresh() }
    }

    func activityChanged() {
        updatePolling()
    }
}

/// A query's identity within one node: the command and its payload as canonical JSON.
struct QueryKey: Hashable, Sendable {
    let command: WsCommand
    let payload: String

    init(_ command: WsCommand, _ payload: some Encodable) {
        self.command = command
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.payload = (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// MARK: - Mutation results

/// What a mutation came to.
public enum MutationResult<R: WsRequest>: Sendable {
    case success(R.Response)
    /// The daemon wants a person to accept something first: present ``ConfirmationRequest/message`` and, if they
    /// agree, ``NodeQueries/accept(_:)``.
    case needsConfirmation(ConfirmationRequest<R>)
    case failure(WsError)
}

/// A `needsConfirmation` refusal to put in front of a person: the daemon's question, and what the contract says
/// about it. Accepting resends the same payload with the command's accept field set.
public struct ConfirmationRequest<R: WsRequest>: Identifiable, Sendable {
    public let id = UUID()
    /// The refusal's `data.code` (`vault_upstream_key_loss`).
    public let code: String
    /// The daemon's question, written for the person.
    public let message: String
    /// The contract's description of the confirmation; nil for a code this build doesn't know (a newer daemon).
    public let confirmation: WsConfirmation?
    /// The payload that was refused.
    public let payload: R.Payload
    let accepted: Set<String>
    let invalidating: [String]

    /// Whether a resend can accept it. Otherwise the contract's summary says what to do instead.
    public var isAcceptable: Bool { confirmation?.acceptField != nil }
}

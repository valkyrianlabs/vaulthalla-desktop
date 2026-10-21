public import Observation
public import VHContract
public import VHTransport

/// A mutation as view state: whether it runs, its outcome, and the confirmation the daemon asked for, which a view
/// binds to a `.confirmationDialog` or sheet (``confirmation``) and answers with ``confirm()``.
///
///     @State private var rename: NodeMutation<Ws.Storage.Vault.Update>?
///     ...
///     await rename.run(.init(id: vault.id, name: .value(newName)))
@MainActor
@Observable
public final class NodeMutation<R: WsRequest> where R.Payload: Decodable {
    public enum Phase {
        case idle
        case running
        case succeeded(R.Response)
        case failed(WsError)
    }

    public private(set) var phase: Phase = .idle
    /// The confirmation the daemon asked for; set it to nil to decline.
    public var confirmation: ConfirmationRequest<R>?

    @ObservationIgnored private let store: NodeQueries
    @ObservationIgnored private let invalidating: [String]

    /// `invalidating`: command prefixes whose queries are stale after a success.
    public init(_ request: R.Type, on store: NodeQueries, invalidating: [String] = []) {
        self.store = store
        self.invalidating = invalidating
    }

    public var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    public var error: WsError? {
        if case .failed(let error) = phase { return error }
        return nil
    }

    /// Sends `payload`. `accepting`: confirmation codes the person already accepted in the view.
    @discardableResult
    public func run(_ payload: R.Payload, accepting: Set<String> = []) async -> R.Response? {
        confirmation = nil
        phase = .running
        return settle(await store.perform(R.self, payload, invalidating: invalidating, accepting: accepting))
    }

    /// Resends with the pending confirmation accepted.
    @discardableResult
    public func confirm() async -> R.Response? {
        guard let request = confirmation else { return nil }
        confirmation = nil
        phase = .running
        return settle(await store.accept(request))
    }

    public func reset() {
        phase = .idle
        confirmation = nil
    }

    private func settle(_ result: MutationResult<R>) -> R.Response? {
        switch result {
        case .success(let response):
            phase = .succeeded(response)
            return response
        case .needsConfirmation(let request):
            phase = .idle
            confirmation = request
        case .failure(let error):
            phase = .failed(error)
        }
        return nil
    }
}

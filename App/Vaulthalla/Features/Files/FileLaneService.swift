import Foundation
import VHContract
import VHCore
import VHNodes
import VHTransport

/// What the file browser needs from the device listener's HTTP lanes. The live service goes through the node's
/// session (``NodeFileLanes``); DEBUG previews use canned images (`PreviewFileLanes`).
nonisolated protocol FileLaneService: Sendable {
    func thumbnailStatus(vaultID: Int64, items: [VaultLanes.ThumbnailItem], size: Int)
        async throws(TransferError) -> [String: VaultLanes.ThumbnailStatus]
    func thumbnail(vaultID: Int64, path: String, size: Int) async throws(TransferError) -> Data
    func download(vaultID: Int64, path: String, isDirectory: Bool, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(TransferError) -> Int64
    /// Uploads `files`. `id` names the upload: on a node with resumable uploads its progress is persisted under that
    /// id, so running it again (Retry, or the next launch) resumes it; `control` says whether a cancel suspends it
    /// (the app quitting) or gives it up.
    func upload(_ files: [VaultLanes.UploadFile], vaultID: Int64, into directory: String, id: UUID,
                control: UploadControl, progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError) -> Set<String>
    /// Uploads an earlier run persisted and didn't finish.
    func pendingUploads() async -> [ResumableUploadRecord]
    /// Gives up an upload kept for resuming: its session on the node and its persisted record.
    func discardUpload(_ id: UUID) async
    /// The node's transfer tuning and live stats (the connection status view); nil without a node.
    nonisolated var transferMonitor: TransferMonitor? { get }
    /// Measures the link now ("Test Connection"); writes nothing on the node.
    func testConnection() async throws(TransferError) -> TransferCalibrator.Result
}

extension FileLaneService {
    func pendingUploads() async -> [ResumableUploadRecord] { [] }
    func discardUpload(_ id: UUID) async {}
    nonisolated var transferMonitor: TransferMonitor? { nil }
    func testConnection() async throws(TransferError) -> TransferCalibrator.Result { throw .laneUnavailable(.transfer) }
}

/// The node's lanes as its current session reaches them: the endpoint the session selected, this Mac's identity for
/// the node and the pinned server key. The client is made on first use and again after a key rotation (the old
/// identity stops being accepted) or when a new selection moved the endpoint (the old client is then left to finish
/// what it carries, not cancelled). A connection failure on a lane asks the session to select again; once the lanes
/// moved, the request runs again there (the server's transfer-protocol.md §2), and a resumable upload resumes its
/// session on the new endpoint by itself (``VaultLanes/reroute``).
///
/// Each lane is checked against what the node announced in `meta.hello` (`device.lanes.*`): a node known not to
/// serve it isn't asked (``TransferError/laneUnavailable(_:)``), and a 404 there means the lane, not the item. On a
/// legacy node (nothing announced) a 404 stays "this item no longer exists", as before. Uploads are resumable where
/// the node announces `http.upload.resumable` (persisted in Application Support/Vaulthalla/Uploads/<node>), and every
/// transfer feeds the node's ``transferMonitor`` (tuning, live stats, the estimate cache).
actor NodeFileLanes: FileLaneService {
    private let session: @MainActor @Sendable () -> NodeSession?
    private var cached: (identity: String, endpoint: NodeEndpoint, lanes: VaultLanes)?
    nonisolated let transferMonitor: TransferMonitor?
    private let store: ResumableStore

    /// Link estimates for every node, kept 24 h (Application Support/Vaulthalla/transfer-estimates.json).
    static let estimates = TransferEstimateCache(file: support.appending(path: "transfer-estimates.json"))
    private static var support: URL {
        URL.applicationSupportDirectory.appending(path: "Vaulthalla", directoryHint: .isDirectory)
    }

    init(nodeID: NodeID, session: @escaping @MainActor @Sendable () -> NodeSession?) {
        self.session = session
        transferMonitor = TransferMonitor(node: nodeID.rawValue, cache: Self.estimates)
        store = ResumableStore(directory: Self.support.appending(path: "Uploads/\(nodeID.rawValue)",
                                                                 directoryHint: .isDirectory))
    }

    deinit {
        cached?.lanes.invalidate()
    }

    /// The lanes for `lane`, and what the node announced for it.
    private func lanes(for lane: TransferError.Lane) async throws(TransferError) -> (VaultLanes, ProtocolSupport) {
        guard let session = await session(),
              let identity = await session.laneIdentityID,
              let configuration = await session.laneConfiguration()
        else { throw .connection("not connected to the node") }
        if let mismatch = await session.nodeProtocol?.mismatch { throw .protocolUnsupported(mismatch.message) }
        let support = await session.supports(capability: lane.capability)
        if support == .no { throw .laneUnavailable(lane) }
        // Gated on what the node announced; unknown (a legacy node) keeps the older lanes.
        let features = VaultLanes.Features(
            resumableUploads: await session.supports(capability: .resumableUpload) == .yes,
            transferLanes: await session.supports(capability: .transferLane) == .yes)
        // The selected route's class (the host heuristic only without a route for this endpoint).
        transferMonitor?.setEndpointClass(TransferEndpointClass(endpoint: configuration.endpoint,
                                                                route: await session.route))
        if let cached, cached.identity == identity, cached.endpoint == configuration.endpoint {
            return (equipped(cached.lanes, features, lane: lane), support)
        }
        // A rotated key is refused anyway: cancel what the old client carries. A moved endpoint isn't: transfers in
        // flight there finish (or fail over themselves), and the client goes with its last user.
        if cached?.identity != identity { cached?.lanes.invalidate() }
        do {
            let made = try VaultLanes(configuration: configuration)
            cached = (identity, configuration.endpoint, made)
            return (equipped(made, features, lane: lane), support)
        } catch {
            throw .connection("the node's address can't be used")
        }
    }

    private func equipped(_ lanes: VaultLanes, _ features: VaultLanes.Features, lane: TransferError.Lane)
        -> VaultLanes
    {
        var lanes = lanes
        lanes.features = features
        lanes.monitor = transferMonitor
        lanes.store = store
        let endpoint = lanes.endpoint
        lanes.reroute = { [weak self] in await self?.rerouted(from: endpoint, lane: lane)?.transfers }
        return lanes
    }

    /// A connection-class failure on `endpoint`: the session selects again; once its lanes moved elsewhere, the
    /// lanes there (nil when they stayed).
    private func rerouted(from endpoint: NodeEndpoint, lane: TransferError.Lane) async -> VaultLanes? {
        guard let session = await session(), await session.rerouteLanes(awayFrom: endpoint) != nil,
              let moved = try? await lanes(for: lane), moved.0.endpoint != endpoint
        else { return nil }
        return moved.0
    }

    /// Runs `body` on the lane, reading its failure against what the node announced. A connection failure asks the
    /// session to select again; with `retryOnNewRoute`, `body` runs once more on the new endpoint when the lanes
    /// moved (previews don't wait for that, and resumable uploads move by themselves).
    private func on<T: Sendable>(_ lane: TransferError.Lane, retryOnNewRoute: Bool = true,
                                 _ body: (VaultLanes) async throws(TransferError) -> T)
        async throws(TransferError) -> T
    {
        let (lanes, support) = try await lanes(for: lane)
        do throws(TransferError) {
            return try await body(lanes)
        } catch {
            guard case .connection = error else { throw error.interpreted(for: lane, support: support) }
            guard retryOnNewRoute else {
                await session()?.laneConnectionFailed()
                throw error.interpreted(for: lane, support: support)
            }
            guard let moved = await rerouted(from: lanes.endpoint, lane: lane) else {
                throw error.interpreted(for: lane, support: support)
            }
            do throws(TransferError) {
                return try await body(moved)
            } catch {
                if case .connection = error { await session()?.laneConnectionFailed() }
                throw error.interpreted(for: lane, support: support)
            }
        }
    }

    func thumbnailStatus(vaultID: Int64, items: [VaultLanes.ThumbnailItem], size: Int)
        async throws(TransferError) -> [String: VaultLanes.ThumbnailStatus]
    {
        try await on(.preview, retryOnNewRoute: false) { lanes throws(TransferError) in
            try await lanes.thumbnailStatus(vaultID: vaultID, items: items, size: size)
        }
    }

    func thumbnail(vaultID: Int64, path: String, size: Int) async throws(TransferError) -> Data {
        try await on(.preview, retryOnNewRoute: false) { lanes throws(TransferError) in
            try await lanes.thumbnail(vaultID: vaultID, path: path, size: size)
        }
    }

    func download(vaultID: Int64, path: String, isDirectory: Bool, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(TransferError) -> Int64 {
        try await on(.download) { lanes throws(TransferError) in
            try await lanes.download(vaultID: vaultID, path: path, isDirectory: isDirectory, to: destination,
                                     progress: progress)
        }
    }

    func upload(_ files: [VaultLanes.UploadFile], vaultID: Int64, into directory: String, id: UUID,
                control: UploadControl, progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError) -> Set<String>
    {
        let store = store
        // Resumable uploads follow a new route themselves (VaultLanes.reroute); the session flow runs again on it.
        let resumable = try await lanes(for: .upload).0.features.resumableUploads
        return try await on(.upload, retryOnNewRoute: !resumable) { lanes throws(TransferError) in
            guard lanes.features.resumableUploads else {
                // The session flow, exactly as before.
                return try await lanes.uploadSessions(files, vaultID: vaultID, into: directory, progress: progress)
            }
            let record = store.load(id) ?? ResumableUploader.plan(files, vaultID: vaultID, into: directory, id: id)
            return try await lanes.uploadResumable(record, control: control, progress: progress)
        }
    }

    func pendingUploads() async -> [ResumableUploadRecord] {
        store.all()
    }

    func discardUpload(_ id: UUID) async {
        guard let record = store.load(id) else { return }
        if let (lanes, _) = try? await lanes(for: .upload), lanes.features.resumableUploads {
            lanes.resumableUploader.discard(record)
        } else {
            // Unreachable now: the node forgets the session itself once it expires (24 h idle).
            store.remove(id)
        }
    }

    func testConnection() async throws(TransferError) -> TransferCalibrator.Result {
        try await on(.transfer, retryOnNewRoute: false) { lanes throws(TransferError) in
            try await lanes.testConnection()
        }
    }
}

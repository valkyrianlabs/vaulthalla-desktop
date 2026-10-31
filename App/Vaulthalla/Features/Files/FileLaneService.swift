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

/// The node's lanes as its current session reaches them: this Mac's identity for the node and the pinned server key.
/// The client is made on first use and again after a key rotation (the old identity stops being accepted).
///
/// Each lane is checked against what the node announced in `meta.hello` (`device.lanes.*`): a node known not to
/// serve it isn't asked (``TransferError/laneUnavailable(_:)``), and a 404 there means the lane, not the item. On a
/// legacy node (nothing announced) a 404 stays "this item no longer exists", as before. Uploads are resumable where
/// the node announces `http.upload.resumable` (persisted in Application Support/Vaulthalla/Uploads/<node>), and every
/// transfer feeds the node's ``transferMonitor`` (tuning, live stats, the estimate cache).
actor NodeFileLanes: FileLaneService {
    private let session: @MainActor @Sendable () -> NodeSession?
    private var cached: (identity: String, lanes: VaultLanes)?
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
            resumableUploads: await session.supports(capability: .httpUploadResumable) == .yes,
            transferLanes: await session.supports(capability: .deviceLanesTransfer) == .yes)
        transferMonitor?.setEndpointClass(TransferEndpointClass(host: configuration.endpoint.host))
        if let cached, cached.identity == identity { return (equipped(cached.lanes, features), support) }
        cached?.lanes.invalidate()
        do {
            let made = try VaultLanes(configuration: configuration)
            cached = (identity, made)
            return (equipped(made, features), support)
        } catch {
            throw .connection("the node's address can't be used")
        }
    }

    private func equipped(_ lanes: VaultLanes, _ features: VaultLanes.Features) -> VaultLanes {
        var lanes = lanes
        lanes.features = features
        lanes.monitor = transferMonitor
        lanes.store = store
        return lanes
    }

    /// Runs `body` on the lane, reading its failure against what the node announced.
    private func on<T: Sendable>(_ lane: TransferError.Lane, _ body: (VaultLanes) async throws(TransferError) -> T)
        async throws(TransferError) -> T
    {
        let (lanes, support) = try await lanes(for: lane)
        do throws(TransferError) {
            return try await body(lanes)
        } catch {
            throw error.interpreted(for: lane, support: support)
        }
    }

    func thumbnailStatus(vaultID: Int64, items: [VaultLanes.ThumbnailItem], size: Int)
        async throws(TransferError) -> [String: VaultLanes.ThumbnailStatus]
    {
        try await on(.preview) { lanes throws(TransferError) in
            try await lanes.thumbnailStatus(vaultID: vaultID, items: items, size: size)
        }
    }

    func thumbnail(vaultID: Int64, path: String, size: Int) async throws(TransferError) -> Data {
        try await on(.preview) { lanes throws(TransferError) in
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
        return try await on(.upload) { lanes throws(TransferError) in
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
        try await on(.transfer) { lanes throws(TransferError) in try await lanes.testConnection() }
    }
}

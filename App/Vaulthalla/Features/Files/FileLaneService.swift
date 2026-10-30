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
    func upload(_ files: [VaultLanes.UploadFile], vaultID: Int64, into directory: String,
                progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError) -> Set<String>
}

/// The node's lanes as its current session reaches them: this Mac's identity for the node and the pinned server key.
/// The client is made on first use and again after a key rotation (the old identity stops being accepted).
///
/// Each lane is checked against what the node announced in `meta.hello` (`device.lanes.*`): a node known not to
/// serve it isn't asked (``TransferError/laneUnavailable(_:)``), and a 404 there means the lane, not the item. On a
/// legacy node (nothing announced) a 404 stays "this item no longer exists", as before.
actor NodeFileLanes: FileLaneService {
    private let session: @MainActor @Sendable () -> NodeSession?
    private var cached: (identity: String, lanes: VaultLanes)?

    init(session: @escaping @MainActor @Sendable () -> NodeSession?) {
        self.session = session
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
        if let cached, cached.identity == identity { return (cached.lanes, support) }
        cached?.lanes.invalidate()
        do {
            let made = try VaultLanes(configuration: configuration)
            cached = (identity, made)
            return (made, support)
        } catch {
            throw .connection("the node's address can't be used")
        }
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

    func upload(_ files: [VaultLanes.UploadFile], vaultID: Int64, into directory: String,
                progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError) -> Set<String>
    {
        try await on(.upload) { lanes throws(TransferError) in
            try await lanes.upload(files, vaultID: vaultID, into: directory, progress: progress)
        }
    }
}

import Foundation
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
actor NodeFileLanes: FileLaneService {
    private let session: @MainActor @Sendable () -> NodeSession?
    private var cached: (identity: String, lanes: VaultLanes)?

    init(session: @escaping @MainActor @Sendable () -> NodeSession?) {
        self.session = session
    }

    deinit {
        cached?.lanes.invalidate()
    }

    private func lanes() async throws(TransferError) -> VaultLanes {
        guard let session = await session(),
              let identity = await session.laneIdentityID,
              let configuration = await session.laneConfiguration()
        else { throw .connection("not connected to the node") }
        if let cached, cached.identity == identity { return cached.lanes }
        cached?.lanes.invalidate()
        do {
            let made = try VaultLanes(configuration: configuration)
            cached = (identity, made)
            return made
        } catch {
            throw .connection("the node's address can't be used")
        }
    }

    func thumbnailStatus(vaultID: Int64, items: [VaultLanes.ThumbnailItem], size: Int)
        async throws(TransferError) -> [String: VaultLanes.ThumbnailStatus]
    {
        try await lanes().thumbnailStatus(vaultID: vaultID, items: items, size: size)
    }

    func thumbnail(vaultID: Int64, path: String, size: Int) async throws(TransferError) -> Data {
        try await lanes().thumbnail(vaultID: vaultID, path: path, size: size)
    }

    func download(vaultID: Int64, path: String, isDirectory: Bool, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(TransferError) -> Int64 {
        let lanes = try await lanes()
        return try await lanes.download(vaultID: vaultID, path: path, isDirectory: isDirectory, to: destination,
                                        progress: progress)
    }

    func upload(_ files: [VaultLanes.UploadFile], vaultID: Int64, into directory: String,
                progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError) -> Set<String>
    {
        let lanes = try await lanes()
        return try await lanes.upload(files, vaultID: vaultID, into: directory, progress: progress)
    }
}

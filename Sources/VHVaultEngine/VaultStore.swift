public import Foundation

/// What a store call failed with, as the engine's store table reports it (vl_vaultfmt_engine.h, statuses 600 to 603 and
/// "not found"). A write whose outcome isn't known is ``outcomeUnknown``, never a guess.
public enum StoreError: Error, Sendable, Equatable {
    case notFound
    case preconditionFailed
    case conditionsUnsupported
    case outcomeUnknown(String)
    case failed(String)

    var status: Int32 {
        switch self {
        case .notFound: VaultStatus.notFound
        case .preconditionFailed: VaultStatus.storePreconditionFailed
        case .conditionsUnsupported: VaultStatus.storeConditionsUnsupported
        case .outcomeUnknown: VaultStatus.storeOutcomeUnknown
        case .failed: VaultStatus.storeFailed
        }
    }
}

/// A PUT's condition (`VL_VAULTFMT_PUT_*`).
public enum PutCondition: Sendable, Equatable {
    case none
    case ifAbsent
    case ifMatch(String)
}

/// An object's identity as the provider answers it: the ETag (quoted, as sent) and the version id (versioned buckets).
public struct StoredObject: Sendable, Equatable {
    public var etag: String?
    public var versionID: String?

    public init(etag: String?, versionID: String?) {
        self.etag = etag
        self.versionID = versionID
    }
}

public struct ObjectBody: Sendable {
    public var bytes: Data
    public var object: StoredObject

    public init(bytes: Data, object: StoredObject) {
        self.bytes = bytes
        self.object = object
    }
}

public struct ListedObject: Sendable, Equatable {
    public var key: String
    public var size: UInt64
    /// Unix seconds.
    public var lastModified: Int64
    public var etag: String

    public init(key: String, size: UInt64, lastModified: Int64, etag: String) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.etag = etag
    }
}

public struct ListedVersion: Sendable, Equatable {
    public var key: String
    public var versionID: String
    public var size: UInt64
    public var lastModified: Int64
    public var deleteMarker: Bool
    public var etag: String
    public var isLatest: Bool

    public init(key: String, versionID: String, size: UInt64, lastModified: Int64, deleteMarker: Bool, etag: String,
                isLatest: Bool) {
        self.key = key
        self.versionID = versionID
        self.size = size
        self.lastModified = lastModified
        self.deleteMarker = deleteMarker
        self.etag = etag
        self.isLatest = isLatest
    }
}

/// One streamed content PUT: bytes in order, then finish (or abort, which never fails).
public protocol ContentUpload: AnyObject, Sendable {
    func write(_ bytes: UnsafeRawBufferPointer) throws(StoreError)
    func finish() throws(StoreError) -> StoredObject
    func abort()
}

/// The bucket of one vault, as the engine's store table needs it (`vl_vaultfmt_store_table`). Calls are synchronous:
/// the engine calls them on the thread that called into the vault (``Vault`` runs every call off Swift's cooperative
/// pool), possibly from two threads at once. A call that can't tell whether a write happened throws
/// ``StoreError/outcomeUnknown(_:)``.
public protocol VaultStore: Sendable {
    /// `VL_VAULTFMT_MODE_VERSION_LOG` for every Desktop-only vault; conditional buckets for tests.
    var versionLog: Bool { get }
    func get(_ key: String, versionID: String?) throws(StoreError) -> ObjectBody
    /// Bytes [offset, offset + length) (fewer at the end) and the object's total size.
    func getRange(_ key: String, versionID: String?, offset: UInt64, length: UInt64) throws(StoreError)
        -> (bytes: Data, total: UInt64)
    func head(_ key: String) throws(StoreError) -> StoredObject
    func put(_ key: String, _ bytes: UnsafeRawBufferPointer, condition: PutCondition) throws(StoreError) -> StoredObject
    func list(prefix: String) throws(StoreError) -> [ListedObject]
    /// The versions of exactly `key` (`underPrefix` false; newest first) or of every key under the prefix `key`
    /// (keys ascending, each key's newest first). Empty on an unversioned bucket.
    func versions(_ key: String, stopAt: String?, underPrefix: Bool) throws(StoreError) -> [ListedVersion]
    /// By name (a delete marker on a versioned bucket) or exactly `versionID`. Gone already is success.
    func remove(_ key: String, versionID: String?) throws(StoreError)
    /// A streamed plain PUT of a content object; `size` is the sealed size when known.
    func beginContent(_ key: String, size: UInt64?) throws(StoreError) -> any ContentUpload
    /// Called once the vault is open (its state locked to this process): aborts the multipart uploads this
    /// installation started for the vault and left behind (a crash, an abort the provider didn't take), once they are
    /// old enough. Best effort; never fails the open, never touches a completed object.
    func cleanUpAbandonedUploads()
}

extension VaultStore {
    public func cleanUpAbandonedUploads() {}
}

import FileProvider
import Foundation
import UniformTypeIdentifiers
import VHFinder

/// A replica entry as the File Provider sees it: identifiers, name, kind, size, dates, version and capabilities, all
/// from ``FinderItem`` (the server's entry). Immutable once made.
final class ReplicaItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let item: FinderItem
    private let root: Int64?

    init(_ item: FinderItem, root: Int64?) {
        self.item = item
        self.root = root
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(item.identifier(root: root).rawValue)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(item.parentIdentifier(root: root).rawValue)
    }

    var filename: String { item.name.isEmpty ? "Vault" : item.name }

    var contentType: UTType {
        switch item.kind {
        case .directory: .folder
        case .symlink: .symbolicLink
        case .file: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
        }
    }

    var documentSize: NSNumber? { item.kind == .file ? NSNumber(value: item.size) : nil }
    var creationDate: Date? { item.created }
    var contentModificationDate: Date? { item.modified }
    var symlinkTargetPath: String? { item.symlinkTarget }

    var itemVersion: NSFileProviderItemVersion {
        let version = item.version
        return NSFileProviderItemVersion(contentVersion: version.content, metadataVersion: version.metadata)
    }

    var capabilities: NSFileProviderItemCapabilities {
        NSFileProviderItemCapabilities(rawValue: item.capabilities.rawValue)
    }

    /// Lazy: nothing is downloaded until it is opened, and a local copy goes when the server's file changes
    /// (vaulthalla/desktop#4). Set on the root; everything below inherits it.
    var contentPolicy: NSFileProviderContentPolicy {
        item.isRoot ? .downloadLazilyAndEvictOnRemoteUpdate : .inherited
    }
}

extension FinderError {
    /// The error the File Provider expects for this failure, with the POSIX code underneath.
    var nsError: NSError {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(posixCode),
                                 userInfo: [NSLocalizedDescriptionKey: description])
        func provider(_ code: NSFileProviderError.Code) -> NSError {
            NSError(domain: NSFileProviderErrorDomain, code: code.rawValue,
                    userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedFailureReasonErrorKey: description])
        }
        return switch self {
        case .notAuthenticated: provider(.notAuthenticated)
        case .serverUnreachable: provider(.serverUnreachable)
        case .noSuchItem: provider(.noSuchItem)
        case .filenameCollision: provider(.filenameCollision)
        case .insufficientQuota: provider(.insufficientQuota)
        case .cannotSynchronize: provider(.cannotSynchronize)
        case .deletionRejected: provider(.deletionRejected)
        case .directoryNotEmpty: provider(.directoryNotEmpty)
        case .versionNoLongerAvailable: provider(.versionNoLongerAvailable)
        case .localVersionConflictingWithServer: provider(.localVersionConflictingWithServer)
        case .syncAnchorExpired: provider(.syncAnchorExpired)
        case .excludedFromSync: provider(.excludedFromSync)
        case .readNotPermitted:
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                    userInfo: [NSUnderlyingErrorKey: underlying])
        case .cancelled:
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [NSUnderlyingErrorKey: underlying])
        case .transient:
            // Not a File Provider error: the system treats it as transient and retries.
            underlying
        }
    }
}

import FileProvider
import Foundation
import os
import UniformTypeIdentifiers
import VHCore
import VHFinder
import VHNodes

/// Vaulthalla's File Provider extension: one domain per vault the operator selects (valkyrianlabs/vaulthalla-desktop#1, #4).
///
/// This is the foundation only (docs/architecture.md §7). The domain shows an empty, read-only root and an empty
/// working set, and every file operation is refused. What it does now is find the shared state the way the full
/// extension will. It reads the node registry in the App Group container and the device identity in the shared
/// keychain group as a read-only consumer (`CredentialReader`), and logs whether the domain's node is ready. It
/// never takes the credential lease, so it can't write the registry or create, rotate or delete keys.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    private let context: ExtensionContext

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        context = ExtensionContext()
        super.init()
        let identifier = domain.identifier.rawValue
        let context = context
        ExtensionContext.log.notice(
            "started for domain \(identifier, privacy: .private) in \(context.registryDescription, privacy: .private)")
        Task {
            let readiness = await context.readiness(for: identifier)
            if readiness.isReady {
                ExtensionContext.log.notice("\(readiness.description, privacy: .private)")
            } else {
                ExtensionContext.log.error("\(readiness.description, privacy: .private)")
            }
        }
    }

    func invalidate() {
        ExtensionContext.log.info("invalidated for domain \(self.domain.identifier.rawValue, privacy: .private)")
    }

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(RootItem(name: domain.displayName), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest)
        throws -> NSFileProviderEnumerator
    {
        switch containerItemIdentifier {
        case .rootContainer, .workingSet, .trashContainer: EmptyEnumerator()
        default: throw NSFileProviderError(.noSuchItem)
        }
    }

    // MARK: File operations: none yet

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void) -> Progress {
        completionHandler(nil, nil, Self.unsupported)
        return Progress()
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void)
        -> Progress
    {
        completionHandler(nil, [], false, Self.unsupported)
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void)
        -> Progress
    {
        completionHandler(nil, [], false, Self.unsupported)
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping ((any Error)?) -> Void) -> Progress {
        completionHandler(Self.unsupported)
        return Progress()
    }

    private static var unsupported: any Error { NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError) }
}

/// The domain's root: an empty folder that may be listed and read, nothing else.
final class RootItem: NSObject, NSFileProviderItem {
    let filename: String

    init(name: String) {
        filename = name
    }

    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8))
    }
}

/// Lists nothing and never changes: the root, the working set and the trash until enumeration lands.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private static let anchor = NSFileProviderSyncAnchor(Data("empty".utf8))

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor)
    }
}

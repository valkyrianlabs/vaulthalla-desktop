// THROWAWAY SPIKE (vaulthalla/desktop#2). A read-only NSFileProviderReplicatedExtension over a paired node.
import FileProvider
import Foundation
import Security

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderPartialContentFetching {
    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        Spike.log("ext init domain=\(domain.identifier.rawValue) bundle=\(Bundle.main.bundleIdentifier ?? "?") sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil) home=\(NSHomeDirectory())")
        selfCheck()
    }

    /// Q1 evidence: the App Group container and the shared keychain item, read from inside the sandbox.
    private func selfCheck() {
        let expected = Spike.container.flatMap { try? String(contentsOf: $0.appending(path: "expected-secret.txt"), encoding: .utf8) }
        let (status, value, group) = Spike.readSecret()
        Spike.log("ext group container=\(Spike.container?.path ?? "nil") expected-secret=\(expected ?? "nil")")
        Spike.log("ext keychain generic password: \(Spike.describe(status)) value=\(value ?? "nil") group=\(group ?? "nil") matches=\(value != nil && value == expected)")
    }

    func invalidate() {
        Spike.log("ext invalidate domain=\(domain.identifier.rawValue)")
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if identifier == .rootContainer {
            completionHandler(Item.root(), nil)
            return progress
        }
        Task {
            do {
                if let entry = try await Backend.shared.entry(Item.path(for: identifier)) {
                    completionHandler(Item(entry), nil)
                } else {
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
            } catch {
                Spike.log("ext item(for: \(identifier.rawValue)) failed: \(error)")
                completionHandler(nil, NSFileProviderError(.serverUnreachable))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let path = Item.path(for: itemIdentifier)
        Spike.log("ext fetchContents \(path) (full)")
        Task {
            do {
                guard let entry = try await Backend.shared.entry(path) else { throw NSFileProviderError(.noSuchItem) }
                let (data, _) = try await Backend.shared.download(path)
                let url = try temporaryFile()
                try data.write(to: url)
                completionHandler(url, Item(entry), nil)
            } catch {
                Spike.log("ext fetchContents \(path) failed: \(error)")
                completionHandler(nil, nil, error as? NSFileProviderError ?? NSFileProviderError(.serverUnreachable))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    // Q6: ranged materialization.
    func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion,
                              request: NSFileProviderRequest, minimalRange requestedRange: NSRange, aligningTo alignment: Int,
                              options: NSFileProviderFetchContentsOptions = [],
                              completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let path = Item.path(for: itemIdentifier)
        Spike.log("ext fetchPartialContents \(path) minimalRange=\(requestedRange.location)+\(requestedRange.length) alignment=\(alignment) options=\(options.rawValue)")
        Task {
            do {
                guard let entry = try await Backend.shared.entry(path) else { throw NSFileProviderError(.noSuchItem) }
                let size = Int(entry.sizeBytes)
                let start = requestedRange.location - requestedRange.location % alignment
                let wanted = requestedRange.location + requestedRange.length
                let end = min(size, (wanted + alignment - 1) / alignment * alignment)
                let (data, status) = try await Backend.shared.download(path, range: Int64(start)...Int64(end - 1))
                guard status == 206 || status == 200 else { throw NSFileProviderError(.serverUnreachable) }
                let url = try temporaryFile()
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                let fetched: NSRange
                if status == 200 {
                    try handle.write(contentsOf: data)
                    fetched = NSRange(location: 0, length: data.count)
                } else {
                    try handle.seek(toOffset: UInt64(start))
                    try handle.write(contentsOf: data)
                    fetched = NSRange(location: start, length: data.count)
                }
                try handle.close()
                Spike.log("ext fetchPartialContents \(path) returning fetchedRange=\(fetched.location)+\(fetched.length) of \(size)")
                completionHandler(url, Item(entry), fetched, [], nil)
            } catch {
                Spike.log("ext fetchPartialContents \(path) failed: \(error)")
                completionHandler(nil, nil, NSRange(location: 0, length: 0), [],
                                  error as? NSFileProviderError ?? NSFileProviderError(.serverUnreachable))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    private func temporaryFile() throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
        return try manager.temporaryDirectoryURL().appending(path: UUID().uuidString)
    }

    // Read-only spike: no writes.
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        Spike.log("ext enumerator(for: \(containerItemIdentifier.rawValue)) domain=\(domain.identifier.rawValue)")
        switch containerItemIdentifier {
        case .workingSet: return WorkingSetEnumerator()
        case .trashContainer: return EmptyEnumerator()
        default: return FolderEnumerator(path: Item.path(for: containerItemIdentifier))
        }
    }
}

final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    let path: String
    init(path: String) { self.path = path }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let entries = try await Backend.shared.list(path)
                observer.didEnumerate(entries.map(Item.init))
                observer.finishEnumerating(upTo: nil)
            } catch {
                Spike.log("ext enumerateItems \(path) failed: \(error)")
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("folder".utf8)))
    }
}

/// Q4: the working set. A signal makes the system call enumerateChanges; this re-lists the root and reports every
/// top-level entry as updated, so a file added on the server appears.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Spike.log("ext workingSet enumerateItems")
        Task {
            do {
                observer.didEnumerate(try await Backend.shared.list("/").map(Item.init))
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Spike.log("ext workingSet enumerateChanges from anchor=\(String(decoding: anchor.rawValue, as: UTF8.self))")
        Task {
            do {
                let items = try await Backend.shared.list("/").map(Item.init)
                observer.didUpdate(items)
                observer.finishEnumeratingChanges(upTo: Self.anchorNow(), moreComing: false)
                Spike.log("ext workingSet reported \(items.count) updated items: \(items.map(\.filename))")
            } catch {
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchorNow())
    }

    static func anchorNow() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(Int(Date().timeIntervalSince1970 * 1000)).utf8))
    }
}

final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }
}

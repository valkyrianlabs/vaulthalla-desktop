import FileProvider
import Foundation
import os
import UniformTypeIdentifiers
import VHCore
import VHFinder
import VHNodes

/// Vaulthalla's File Provider extension: one domain per vault the operator selects (valkyrianlabs/vaulthalla-desktop#1, #4).
///
/// A thin adapter (docs/architecture.md §7): every call goes to the domain's ``VaultReplica`` (VHFinder, tested by
/// `swift test`), which reaches the node through a ``NodeLink`` as a read-only credential consumer (the registry in the
/// App Group container and the device key in the shared keychain group; it never takes the credential lease). The
/// server decides what the account may do; this maps its answers to File Provider items and errors.
///
/// - Enumeration: folders through `fs.dir.list`, the working set from the replica database; changes by listing the
///   enumerated folders again (no change journal yet, vaulthalla/server#259).
/// - Contents: `/download/content`, whole or as an aligned `Range` with `If-Range` (`NSFileProviderPartialContentFetching`).
/// - Writes: `PUT /upload/content` (`If-None-Match: *` to create, `If-Match` to replace; a conflict keeps the server's
///   version and uploads the local edit as a conflict copy), `fs.dir.create`, `fs.entry.rename`/`move`, and
///   `fs.entry.delete` (into the server's trash and recovery).
/// - Thumbnails: `/preview/batch` and `/preview` (`NSFileProviderThumbnailing`).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderPartialContentFetching,
    NSFileProviderThumbnailing, @unchecked Sendable
{
    let domain: NSFileProviderDomain
    private let context: ExtensionContext
    /// nil when the domain isn't a vault domain this build can serve (no App Group, a foreign identifier).
    private let replica: VaultReplica?
    private let unavailable: FinderError?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        context = ExtensionContext()
        let identifier = domain.identifier.rawValue
        if let vault = VaultDomainID(identifier: identifier), context.registry != nil {
            do throws(FinderError) {
                let link = NodeLink(nodeID: vault.nodeID, reader: context.reader)
                replica = try VaultReplica(vaultID: vault.vaultID, link: link,
                                           storeURL: context.storeURL(for: identifier),
                                           macName: ExtensionContext.macName)
                unavailable = nil
            } catch {
                replica = nil
                unavailable = error
            }
        } else {
            replica = nil
            unavailable = .notAuthenticated(context.registry == nil
                ? "This build has no App Group, so it can't read Vaulthalla's nodes."
                : "\(identifier) isn't a Vaulthalla vault domain.")
        }
        super.init()
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
        if let replica { Task { await replica.close() } }
    }

    // MARK: - Plumbing

    private func serving() throws(FinderError) -> VaultReplica {
        guard let replica else { throw unavailable ?? .notAuthenticated("The domain can't be served.") }
        return replica
    }

    private var manager: NSFileProviderManager? { NSFileProviderManager(for: domain) }

    /// A directory on the replica's volume for downloads the system then clones.
    private func temporaryDirectory() throws(FinderError) -> URL {
        do {
            guard let url = try manager?.temporaryDirectoryURL() else { throw CocoaError(.fileNoSuchFile) }
            return url
        } catch {
            throw .transient("No temporary directory for the domain (\(error.localizedDescription)).")
        }
    }

    /// Asks the system to enumerate the working set's changes: after a write that made more than the item the system
    /// asked for (a conflict copy).
    private func signalWorkingSet() {
        manager?.signalEnumerator(for: .workingSet) { error in
            if let error { ExtensionContext.log.error("signal failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static func itemID(_ identifier: NSFileProviderItemIdentifier) throws(FinderError) -> FinderItemID {
        guard let id = FinderItemID(rawValue: identifier.rawValue) else { throw .noSuchItem }
        return id
    }

    private static func version(_ version: NSFileProviderItemVersion) -> FinderItemVersion {
        FinderItemVersion(content: version.contentVersion, metadata: version.metadataVersion)
    }

    // MARK: - Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void) -> Progress {
        let reply = Reply(completionHandler)
        let task = Task {
            do throws(FinderError) {
                let replica = try serving()
                let item = try await replica.item(try Self.itemID(identifier))
                reply.call(await replica.present(item), nil)
            } catch {
                reply.call(nil, error.nsError)
            }
        }
        return progress(for: task)
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest)
        throws -> NSFileProviderEnumerator
    {
        let replica: VaultReplica
        do {
            replica = try serving()
        } catch {
            throw error.nsError
        }
        switch FinderItemID(rawValue: containerItemIdentifier.rawValue) {
        case .workingSet: return WorkingSetEnumerator(replica: replica)
        case .trash: return EmptyEnumerator()
        case .some(let id): return ContainerEnumerator(replica: replica, container: id)
        case nil: throw FinderError.noSuchItem.nsError
        }
    }

    // MARK: - Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void) -> Progress {
        let reply = Reply(completionHandler)
        let task = Task {
            do throws(FinderError) {
                let replica = try serving()
                let (url, item) = try await replica.fetch(try Self.itemID(itemIdentifier),
                                                          into: try temporaryDirectory())
                reply.call(url, await replica.present(item), nil)
            } catch {
                reply.call(nil, nil, error.nsError)
            }
        }
        return progress(for: task)
    }

    func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion,
                              request: NSFileProviderRequest, minimalRange requestedRange: NSRange,
                              aligningTo alignment: Int, options: NSFileProviderFetchContentsOptions,
                              completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange,
                                                            NSFileProviderMaterializationFlags, (any Error)?) -> Void)
        -> Progress
    {
        let reply = Reply(completionHandler)
        let version = Self.version(requestedVersion)
        let strict = options.contains(.strictVersioning)
        let minimal = Int64(requestedRange.location)..<Int64(requestedRange.location + requestedRange.length)
        let task = Task {
            do throws(FinderError) {
                let replica = try serving()
                let fetched = try await replica.fetchRange(try Self.itemID(itemIdentifier), version: version,
                                                           minimal: minimal, alignment: Int64(alignment),
                                                           strict: strict, into: try temporaryDirectory())
                let range = NSRange(location: Int(fetched.range.lowerBound), length: Int(fetched.range.count))
                reply.call(fetched.url, await replica.present(fetched.item), range, [], nil)
            } catch {
                reply.call(nil, nil, NSRange(location: 0, length: 0), [], error.nsError)
            }
        }
        return progress(for: task)
    }

    // MARK: - Writes

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void)
        -> Progress
    {
        let reply = Reply(completionHandler)
        let kind: FinderItemKind = if itemTemplate.contentType?.conforms(to: .symbolicLink) == true {
            .symlink
        } else if itemTemplate.contentType?.conforms(to: .folder) == true
                    || itemTemplate.contentType?.conforms(to: .directory) == true {
            .directory
        } else {
            .file
        }
        let name = itemTemplate.filename
        let parent = itemTemplate.parentItemIdentifier
        let contents = fields.contains(.contents) ? url : nil
        let mayExist = options.contains(.mayAlreadyExist)
        let task = Task {
            do throws(FinderError) {
                let replica = try serving()
                let template = VaultReplica.Template(name: name, parent: try Self.itemID(parent), kind: kind)
                let made = try await replica.create(template, contents: contents, mayAlreadyExist: mayExist)
                reply.call(await replica.present(made), [], false, nil)
            } catch {
                reply.call(nil, [], false, error.nsError)
            }
        }
        return progress(for: task)
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void)
        -> Progress
    {
        let reply = Reply(completionHandler)
        let identifier = item.itemIdentifier
        let base = Self.version(version)
        let name = changedFields.contains(.filename) ? item.filename : nil
        let parent = changedFields.contains(.parentItemIdentifier) ? item.parentItemIdentifier : nil
        let contents = changedFields.contains(.contents) ? newContents : nil
        let failOnConflict = options.contains(.failOnConflict)
        let task = Task {
            do throws(FinderError) {
                let replica = try serving()
                let changes = VaultReplica.Changeset(name: name, parent: try parent.map(Self.itemID), contents: contents)
                let done = try await replica.modify(try Self.itemID(identifier), base: base, changes: changes,
                                                    failOnConflict: failOnConflict)
                reply.call(await replica.present(done.item), [], done.fetchContents, nil)
                if done.conflictCopy != nil { signalWorkingSet() }
            } catch {
                reply.call(nil, [], false, error.nsError)
            }
        }
        return progress(for: task)
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping ((any Error)?) -> Void) -> Progress {
        let reply = Reply(completionHandler)
        let base = Self.version(version)
        let recursive = options.contains(.recursive)
        let task = Task {
            do throws(FinderError) {
                let replica = try serving()
                try await replica.delete(try Self.itemID(identifier), base: base, recursive: recursive)
                reply.call(nil)
            } catch {
                reply.call(error.nsError)
            }
        }
        return progress(for: task)
    }

    // MARK: - Thumbnails

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, (any Error)?) -> Void,
                         completionHandler: @escaping ((any Error)?) -> Void) -> Progress {
        let each = Reply(perThumbnailCompletionHandler)
        let done = Reply(completionHandler)
        // Points to pixels for a Retina display; the server picks its nearest rendition.
        let pixels = max(64, min(1024, Int(max(size.width, size.height) * 2)))
        let ids = itemIdentifiers.map { ($0, FinderItemID(rawValue: $0.rawValue)) }
        let task = Task {
            do throws(FinderError) {
                let replica = try serving()
                for (identifier, id) in ids where id == nil { each.call(identifier, nil, nil) }
                await replica.thumbnails(for: ids.compactMap(\.1), size: pixels) { id, data, error in
                    each.call(NSFileProviderItemIdentifier(id.rawValue), data, error?.nsError)
                }
                done.call(nil)
            } catch {
                done.call(error.nsError)
            }
        }
        return progress(for: task, total: Int64(itemIdentifiers.count))
    }
}

// MARK: - Finder actions

/// Finder's context menu (desktop#35): Keep Downloaded and its reverse, declared under `NSExtensionFileProviderActions`
/// in Info.plist. Removing a download and downloading now are the system's own items.
extension FileProviderExtension: NSFileProviderCustomAction {
    static let keepDownloadedAction = "sh.vaulthalla.app.fileprovider.keepDownloaded"
    static let allowRemovingDownloadAction = "sh.vaulthalla.app.fileprovider.allowRemovingDownload"

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping ((any Error)?) -> Void) -> Progress {
        let reply = Reply(completionHandler)
        let keep: Bool? = switch actionIdentifier.rawValue {
        case Self.keepDownloadedAction: true
        case Self.allowRemovingDownloadAction: false
        default: nil
        }
        let ids = itemIdentifiers.compactMap { FinderItemID(rawValue: $0.rawValue) }
        let task = Task {
            do throws(FinderError) {
                guard let keep else { throw .transient("Unknown action \(actionIdentifier.rawValue).") }
                try await serving().keepDownloaded(ids, keep)
                // The items took a revision: the working set's changes carry their new content policy.
                signalWorkingSet()
                reply.call(nil)
            } catch {
                reply.call(error.nsError)
            }
        }
        return progress(for: task)
    }
}

import FileProvider
import Foundation
import VHFinder

/// A completion handler handed across to a task. The File Provider calls them from any thread and expects them once.
struct Reply<Handler>: @unchecked Sendable {
    let call: Handler
    init(_ call: Handler) { self.call = call }
}

/// A running operation's progress, cancelling its task when the system cancels it.
func progress(for task: Task<Void, Never>, total: Int64 = 1) -> Progress {
    let progress = Progress(totalUnitCount: total)
    progress.cancellationHandler = { task.cancel() }
    return progress
}

/// One folder's children (`fs.dir.list` through the replica, a page at a time) and, for changes, the replica's.
final class ContainerEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let replica: VaultReplica
    private let container: FinderItemID
    private let tasks = TaskBag()

    init(replica: VaultReplica, container: FinderItemID) {
        self.replica = replica
        self.container = container
    }

    func invalidate() {
        tasks.cancelAll()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Reply(observer)
        let (replica, container) = (replica, container)
        let pageSize = observer.call.suggestedPageSize ?? 200
        let start = EnumerationPage(data: page.rawValue)
        tasks.add(Task {
            do throws(FinderError) {
                let (items, next) = try await replica.list(container, page: start, pageSize: pageSize)
                let root = await replica.rootEntryID
                observer.call.didEnumerate(items.map { ReplicaItem($0, root: root) })
                observer.call.finishEnumerating(upTo: next.map { NSFileProviderPage($0.data) })
            } catch {
                observer.call.finishEnumeratingWithError(error.nsError)
            }
        })
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        ChangeReporter.report(replica: replica, to: observer, from: anchor, tasks: tasks)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let reply = Reply(completionHandler)
        let replica = replica
        tasks.add(Task { reply.call(NSFileProviderSyncAnchor(await replica.currentAnchor.data)) })
    }
}

/// The working set: every entry of every folder the system enumerated, from the replica. Its changes are how
/// the system learns about the server's: the replica lists those folders again and reports the difference.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let replica: VaultReplica
    private let tasks = TaskBag()

    init(replica: VaultReplica) {
        self.replica = replica
    }

    func invalidate() {
        tasks.cancelAll()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Reply(observer)
        let replica = replica
        let pageSize = observer.call.suggestedPageSize ?? 200
        let start = EnumerationPage(data: page.rawValue)
        tasks.add(Task {
            do throws(FinderError) {
                let (items, next) = try await replica.workingSet(page: start, pageSize: pageSize)
                let root = await replica.rootEntryID
                observer.call.didEnumerate(items.map { ReplicaItem($0, root: root) })
                observer.call.finishEnumerating(upTo: next.map { NSFileProviderPage($0.data) })
            } catch {
                observer.call.finishEnumeratingWithError(error.nsError)
            }
        })
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        ChangeReporter.report(replica: replica, to: observer, from: anchor, tasks: tasks)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let reply = Reply(completionHandler)
        let replica = replica
        tasks.add(Task { reply.call(NSFileProviderSyncAnchor(await replica.currentAnchor.data)) })
    }
}

/// Lists nothing and never changes: the trash, which this domain doesn't sync (`supportsSyncingTrash = false`).
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private static let anchor = NSFileProviderSyncAnchor(Data("vh1:empty".utf8))

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

enum ChangeReporter {
    /// Reports the replica's changes after `anchor` to `observer`: updated items, deleted identifiers, the anchor to
    /// resume from, and whether more follow (the system asks again from there).
    static func report(replica: VaultReplica, to observer: NSFileProviderChangeObserver,
                       from anchor: NSFileProviderSyncAnchor, tasks: TaskBag) {
        let observer = Reply(observer)
        let limit = observer.call.suggestedBatchSize ?? 200
        tasks.add(Task {
            guard let since = SyncAnchor(data: anchor.rawValue) else {
                observer.call.finishEnumeratingWithError(FinderError.syncAnchorExpired.nsError)
                return
            }
            do throws(FinderError) {
                let changes = try await replica.changes(since: since, limit: limit)
                let root = await replica.rootEntryID
                if !changes.updated.isEmpty {
                    observer.call.didUpdate(changes.updated.map { ReplicaItem($0, root: root) })
                }
                if !changes.deleted.isEmpty {
                    observer.call.didDeleteItems(withIdentifiers: changes.deleted.map {
                        NSFileProviderItemIdentifier($0.rawValue)
                    })
                }
                observer.call.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(changes.anchor.data),
                                                       moreComing: changes.moreComing)
            } catch {
                observer.call.finishEnumeratingWithError(error.nsError)
            }
        })
    }
}

/// Tasks an enumerator started, cancelled together when the system invalidates it.
final class TaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func add(_ task: Task<Void, Never>) {
        lock.withLock {
            // Finished tasks need no handle; keep the recent ones (dropping a handle doesn't cancel its task).
            if tasks.count >= 64 { tasks.removeFirst(tasks.count - 63) }
            tasks.append(task)
        }
    }

    func cancelAll() {
        lock.withLock {
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }
}

import Foundation
import Observation
import VHContract
import VHNodes
import VHTransport

/// The words and limits of the conflict screens, as the web console has them (features/syncConflicts/model.ts).
nonisolated enum ConflictResolution {
    typealias Choice = Ws.Sync.Conflicts.Resolve.Payload.Resolution

    /// The daemon takes at most this many ids per `sync.conflicts.resolve`; larger selections go in consecutive calls.
    static let batchSize = 500

    static let noOverwrite = "You need Overwrite permission on this file to resolve it."

    static func label(_ choice: Choice) -> String {
        switch choice {
        case .keepLocal: "Keep Local"
        case .keepRemote: "Keep Remote"
        }
    }

    static func effect(_ choice: Choice) -> String {
        switch choice {
        case .keepLocal: "The vault's copy is uploaded over the bucket's."
        case .keepRemote: "The bucket's copy is downloaded over the vault's."
        }
    }

    static func label(resolution: String) -> String {
        Choice(rawValue: resolution).map(label) ?? Format.words(resolution)
    }

    static func status(_ status: String) -> String {
        typealias Status = WsModel.SyncConflictResolveResult.Result.Status
        switch status {
        case Status.resolved: return "Resolved"
        case Status.denied: return "Not allowed"
        case Status.notFound: return "Not found"
        case Status.conflict: return "Changed since recorded"
        case Status.invalid: return "Invalid"
        case Status.unavailable: return "Transfer refused"
        case Status.error: return "Failed"
        default: return Format.words(status)
        }
    }

    /// The ids in requests of at most ``batchSize``, duplicates dropped, order kept.
    static func batches(_ ids: [Int64]) -> [[Int64]] {
        var seen: Set<Int64> = []
        let unique = ids.filter { seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: batchSize).map {
            Array(unique[$0..<min($0 + batchSize, unique.count)])
        }
    }
}

/// One finished run of Keep Local / Keep Remote, for the results panel.
struct ConflictRun: Identifiable {
    struct Item: Identifiable {
        var id: Int64
        /// "Vault: path", captured before the list refetches (resolved rows leave it).
        var place: String
        var status: String
        var message: String?
        var tone: StatusTone
    }

    let id = UUID()
    var choice: ConflictResolution.Choice
    var resolved: Int64 = 0
    /// Items the daemon refused, or that were never sent (a request failed, or a confirmation was declined).
    var failures: [Item] = []
    /// Why the run stopped early, when it did.
    var stopped: String?

    var title: String {
        let notResolved = failures.count
        return "\(ConflictResolution.label(choice)): \(resolved) resolved, \(notResolved) not resolved"
    }
}

/// Runs resolutions in batches and keeps what views show about them: which rows are busy, the last run, and a
/// confirmation the daemon asked for. A `needsConfirmation` refusal is put to the person in the daemon's words and
/// resent with the acceptance only if they agree (``answer(_:)``), like `.serverConfirmation` does for one request.
@MainActor
@Observable
final class ConflictResolver {
    private(set) var busy: Set<Int64> = []
    private(set) var running: ConflictResolution.Choice?
    var lastRun: ConflictRun?
    /// The daemon's question while a run waits for the person.
    private(set) var confirmation: ConfirmationRequest<Ws.Sync.Conflicts.Resolve>?

    @ObservationIgnored private let queries: NodeQueries
    @ObservationIgnored private var pending: CheckedContinuation<Bool, Never>?

    init(queries: NodeQueries) {
        self.queries = queries
    }

    var isRunning: Bool { running != nil }

    /// Resolves `targets` (id and "vault: path"). Returns the run, also kept as ``lastRun``.
    @discardableResult
    func resolve(_ choice: ConflictResolution.Choice, _ targets: [(id: Int64, place: String)]) async -> ConflictRun {
        let places = Dictionary(targets.map { ($0.id, $0.place) }, uniquingKeysWith: { a, _ in a })
        var run = ConflictRun(choice: choice)
        let batches = ConflictResolution.batches(targets.map(\.id))
        running = choice
        busy.formUnion(places.keys)
        defer {
            busy.subtract(places.keys)
            running = nil
            queries.invalidate(prefix: "sync.conflicts")
        }

        for (index, batch) in batches.enumerated() {
            var result = await queries.perform(Ws.Sync.Conflicts.Resolve.self,
                                               .init(resolution: choice, conflictIDs: batch))
            while case .needsConfirmation(let request) = result {
                guard request.isAcceptable, await ask(request) else {
                    result = .failure(.needsConfirmation(code: request.code, message: request.message))
                    break
                }
                result = await queries.accept(request)
            }
            switch result {
            case .success(let response):
                run.resolved += response.resolved
                for item in response.results where !item.ok {
                    run.failures.append(.init(
                        id: item.conflictID, place: places[item.conflictID] ?? "Conflict #\(item.conflictID)",
                        status: ConflictResolution.status(item.status), message: item.message,
                        tone: item.status == WsModel.SyncConflictResolveResult.Result.Status.conflict ? .warn : .danger))
                }
            case .failure(let error):
                // This batch and the ones after it weren't (or may not have been) applied.
                let unsent = batches[index...].flatMap { $0 }
                let (status, tone) = Self.unsent(error)
                run.stopped = Self.reason(error)
                run.failures += unsent.map {
                    .init(id: $0, place: places[$0] ?? "Conflict #\($0)", status: status, message: nil, tone: tone)
                }
                lastRun = run
                return run
            case .needsConfirmation:
                break
            }
        }
        lastRun = run
        return run
    }

    /// The person's answer to ``confirmation``.
    func answer(_ accepted: Bool) {
        confirmation = nil
        pending?.resume(returning: accepted)
        pending = nil
    }

    private func ask(_ request: ConfirmationRequest<Ws.Sync.Conflicts.Resolve>) async -> Bool {
        await withCheckedContinuation { continuation in
            pending = continuation
            confirmation = request
        }
    }

    private static func unsent(_ error: WsError) -> (String, StatusTone) {
        switch QueryProblem(error) {
        case .noAnswerYet: ("No answer yet", .info)
        case .offline: ("Not sent", .info)
        case .denied: ("Not allowed", .warn)
        default: ("Not resolved", .danger)
        }
    }

    private static func reason(_ error: WsError) -> String {
        if case .needsConfirmation = error { return "Stopped: \(error.message)" }
        switch QueryProblem(error) {
        case .noAnswerYet:
            return "The node hasn't answered yet and may still be working on it. Check the list before trying again."
        case .offline: return "The connection to the node was lost. The rest wasn't sent."
        case .denied(let message): return "Not allowed: \(message)"
        default: return error.message
        }
    }
}

/// How the preview can show a conflicted file: images side by side, text as a line diff, otherwise the metadata.
nonisolated enum ConflictPreviewKind {
    case image, text, media, none

    init(_ conflict: WsModel.SyncConflict) {
        typealias Renderer = WsModel.PreviewPlan.Renderer
        let renderer = conflict.preview.renderer
        let mime = (conflict.local.mimeType ?? conflict.remote.mimeType ?? "").lowercased()
        switch renderer {
        case Renderer.image, Renderer.svg, Renderer.imageNative: self = .image
        case Renderer.text, Renderer.markdown: self = .text
        case Renderer.video, Renderer.audio: self = .media
        case "", Renderer.none:
            if mime.hasPrefix("image/") { self = .image }
            else if mime.hasPrefix("text/") || mime == "application/json" { self = .text }
            else if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { self = .media }
            else { self = .none }
        default: self = .none
        }
    }

    /// One side larger than this gets no line diff.
    static let textDiffLimit: Int64 = 2 * 1024 * 1024
    /// The daemon refuses to fetch a bucket copy larger than this for a preview.
    static let remotePreviewLimit: Int64 = 32 * 1024 * 1024
    /// Bucket bytes are metered: anything larger waits for an explicit click.
    static let remoteAutoloadLimit: Int64 = 2 * 1024 * 1024
}

extension WsModel.SyncConflict {
    var place: String { "\(vaultName): \(path)" }
}

import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

extension View {
    /// On the Sync Conflicts sidebar row: the node's open conflict count (`sync.conflicts.summary`, polled every
    /// 60 s while the app is active). Hidden at 0, while loading and when the query fails: the daemon counts only
    /// vaults where this account may resolve conflicts, so a refusal means there's nothing to show. A node whose
    /// `meta.hello` doesn't list the command isn't asked at all.
    func syncConflictsBadge(section: NodeSection, node: Node) -> some View {
        modifier(SyncConflictsBadge(isConflicts: section == .syncConflicts, node: node))
    }
}

private struct SyncConflictsBadge: ViewModifier {
    var isConflicts: Bool
    var node: Node

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if isConflicts, let queries = model.liveQueries(for: node),
           queries.supports(command: .syncConflictsSummary) != .no {
            let summary = queries.query(Ws.Sync.Conflicts.Summary.self)
            // A refusal (or a daemon without the command) won't change by polling; ask again only on a new view.
            let polling: Duration? = summary.error.map(Self.isFinal) == true ? nil : .seconds(60)
            content
                .badge(Self.count(summary))
                .task(id: Key(query: ObjectIdentifier(summary), polls: polling != nil)) {
                    await summary.observe(polling: polling)
                }
        } else {
            content
        }
    }

    private struct Key: Hashable {
        var query: ObjectIdentifier
        var polls: Bool
    }

    private static func count(_ summary: NodeQuery<Ws.Sync.Conflicts.Summary>) -> Int {
        guard summary.error == nil, let total = summary.value?.total, total > 0 else { return 0 }
        return Int(min(total, 9_999))
    }

    private static func isFinal(_ error: WsError) -> Bool {
        switch error {
        case .denied, .unauthorized, .contractMismatch, .unknownCommand, .protocolUnsupported: true
        // A legacy node lists no commands: its "Unknown command" is final too.
        default: error.isUnknownCommand
        }
    }
}

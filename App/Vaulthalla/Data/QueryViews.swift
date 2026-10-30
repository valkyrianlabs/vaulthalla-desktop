import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

extension View {
    /// Keeps `query` fresh while the view is on screen: fetches when stale, then polls every `interval` while the app
    /// is active. Every screen observes its queries through this.
    func observing<R: WsRequest>(_ query: NodeQuery<R>, polling interval: Duration? = nil) -> some View {
        task(id: ObjectIdentifier(query)) { await query.observe(polling: interval) }
    }
}

/// How a failed read reads to a person. The daemon's words where it has them; never an alarm for what is only a
/// slow or lost connection.
enum QueryProblem: Equatable {
    /// RBAC said no: a calm "no access" state, not an error.
    case denied(String)
    case notFound(String)
    case offline
    /// The daemon hasn't answered yet; it may still be working.
    case noAnswerYet
    case mismatch
    case failed(String)

    init(_ error: WsError) {
        switch error {
        case .denied(let message): self = .denied(message)
        case .notFound(let message): self = .notFound(message)
        case .disconnected, .cancelled: self = .offline
        case .timeout: self = .noAnswerYet
        case .contractMismatch: self = .mismatch
        case .unauthorized(let message), .invalid(let message), .conflict(let message), .error(let message),
             .needsConfirmation(_, let message), .refused(_, let message):
            self = .failed(message)
        case .unknownCommand: self = .failed(CompatibilityWords.unknownCommand)
        case .protocolUnsupported(let mismatch): self = .failed(mismatch.message)
        }
    }
}

/// What to say when a node runs another Vaulthalla than this build expects.
enum CompatibilityWords {
    /// The node doesn't have the command (`unknown_command`).
    static let unknownCommand = "This node's Vaulthalla doesn't have this yet. Update Vaulthalla on the node to use it."

    /// An answer that didn't decode (`contractMismatch`). On a legacy node (no `meta.hello`, so ≤ 1.18) the likely
    /// cause is a release older than this build supports: say which one it needs.
    static func mismatch(node: String, legacy: Bool) -> String {
        legacy
            ? "\(node) runs Vaulthalla \(WsProtocol.newestLegacyServer) or earlier and answered in a shape this "
                + "version of Vaulthalla Desktop doesn't understand. Desktop needs Vaulthalla "
                + "\(WsProtocol.oldestServer) or later: update Vaulthalla on the node."
            : "It answered in a shape this version of Vaulthalla Desktop doesn't understand. "
                + "Updating one of them fixes it."
    }

    /// The compact form, for a line in a page.
    static func shortMismatch(legacy: Bool) -> String {
        legacy ? "Needs Vaulthalla \(WsProtocol.oldestServer) or later on the node." : "Not readable by this version."
    }
}

/// Renders a query: progress, its value, or the calm state for its failure. A value refreshed with a failure keeps
/// showing, under a banner that says how old it is.
struct QueryContent<R: WsRequest, Content: View>: View {
    var query: NodeQuery<R>
    var node: Node
    /// What the query shows, for the empty and failure states ("health", "vaults").
    var subject: String
    @ViewBuilder var content: (R.Response) -> Content

    @Environment(NodeQueries.self) private var queries: NodeQueries?

    var body: some View {
        switch query.state {
        case .idle, .loading:
            LoadingPanel(subject: subject)
        case .loaded(let value, let at):
            VStack(alignment: .leading, spacing: Theme.stackSpacing) {
                StaleBanner(node: node, updatedAt: at, refreshError: query.refreshError,
                            connected: queries?.isConnected ?? true)
                content(value)
            }
        case .failed(let error):
            ProblemPanel(problem: QueryProblem(error), node: node, subject: subject) {
                Task { await query.refresh() }
            }
        }
    }
}

struct LoadingPanel: View {
    var subject: String

    var body: some View {
        Panel {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading \(subject)…")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }
}

/// The full-size state for a read that has nothing to show.
struct ProblemPanel: View {
    var problem: QueryProblem
    var node: Node
    var subject: String
    var retry: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        Panel {
            switch problem {
            case .denied(let message):
                EmptyState(
                    "You don't have access to \(subject) on \(node.displayName)",
                    systemImage: "lock",
                    message: "\(message) Access is managed on the node, through the roles of the account this Mac acts for."
                )
            case .notFound(let message):
                EmptyState("Not on \(node.displayName) any more", systemImage: "questionmark.folder", message: message) {
                    Button("Reload", action: retry)
                }
            case .offline:
                EmptyState(
                    "Reconnecting to \(node.displayName)…",
                    systemImage: "bolt.horizontal.circle",
                    message: "\(subject.capitalizedFirst) loads as soon as the connection is back."
                )
            case .noAnswerYet:
                EmptyState(
                    "No answer yet",
                    systemImage: "hourglass",
                    message: "\(node.displayName) hasn't answered. It may still be working on it."
                ) {
                    Button("Ask Again", action: retry)
                }
            case .mismatch:
                EmptyState(
                    "\(node.displayName) runs a different Vaulthalla",
                    systemImage: "arrow.triangle.2.circlepath",
                    message: CompatibilityWords.mismatch(node: node.displayName,
                                                         legacy: model.nodeProtocol(for: node.id)?.isLegacy == true)
                )
            case .failed(let message):
                EmptyState("Couldn't load \(subject)", systemImage: "exclamationmark.triangle", message: message) {
                    Button("Try Again", action: retry)
                }
            }
        }
    }
}

/// A compact failure line for a part of a page (an inspector section) whose neighbours still show.
struct InlineProblem: View {
    var error: WsError
    var subject: String

    @Environment(NodeQueries.self) private var queries: NodeQueries?

    var body: some View {
        let (icon, text): (String, String) = switch QueryProblem(error) {
        case .denied: ("lock", "You don't have access to \(subject).")
        case .notFound(let message): ("questionmark.circle", message)
        case .offline: ("bolt.horizontal.circle", "Not connected.")
        case .noAnswerYet: ("hourglass", "No answer yet.")
        case .mismatch:
            ("arrow.triangle.2.circlepath",
             CompatibilityWords.shortMismatch(legacy: queries?.nodeProtocol?.isLegacy == true))
        case .failed(let message): ("exclamationmark.triangle", message)
        }
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.fgSubtle)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Above data that may be old: the connection is down, or the latest refresh didn't land.
struct StaleBanner: View {
    var node: Node
    var updatedAt: Date
    var refreshError: WsError?
    var connected: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        if let text {
            Callout(tone: .info, systemImage: icon) {
                Text(text)
            }
        }
    }

    private var time: String { updatedAt.formatted(date: .omitted, time: .shortened) }

    private var icon: String {
        switch refreshError.map(QueryProblem.init) {
        case .noAnswerYet: "hourglass"
        case .denied: "lock"
        default: "bolt.horizontal.circle"
        }
    }

    private var text: String? {
        if !connected { return "Showing data from \(time); reconnecting to \(node.displayName)…" }
        guard let refreshError else { return nil }
        return switch QueryProblem(refreshError) {
        case .offline: "Showing data from \(time); reconnecting to \(node.displayName)…"
        case .noAnswerYet: "Showing data from \(time). \(node.displayName) hasn't answered the latest refresh yet."
        case .denied(let message): "Showing data from \(time). The latest refresh was refused: \(message)"
        case .notFound(let message), .failed(let message): "Showing data from \(time). The latest refresh failed: \(message)"
        case .mismatch:
            model.nodeProtocol(for: node.id)?.isLegacy == true
                ? "Showing data from \(time). \(CompatibilityWords.shortMismatch(legacy: true))"
                : "Showing data from \(time). The latest answer wasn't readable by this version."
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

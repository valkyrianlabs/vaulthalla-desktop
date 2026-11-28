import SwiftUI
import VHCore
import VHNodes
import VHTransport

/// Acting on a node's health findings (docs/mac-experience.md §7): acknowledge, silence for a while, turn back on,
/// and the remedies that open a place. The state is the server's; Desktop sends the person's choice and shows the
/// answer. Only a click reaches these: nothing here runs on its own, and the MCP bridge offers none of it.
nonisolated enum FindingActivity: Equatable, Sendable {
    case running
    case failed(String)

    static func key(_ node: NodeID, _ alert: NodeDigest.Alert) -> String { "\(node.rawValue)|\(alert.id)" }
}

extension AppModel {
    /// Runs a person's action on a finding of a node: the menus, the Overview's buttons and a notification's actions
    /// all land here. Returns why the node refused, nil on success; a refusal stays on the finding until the next try.
    @discardableResult
    func act(_ action: HealthFindingAction, on alert: NodeDigest.Alert, node id: NodeID) async -> WsError? {
        let key = FindingActivity.key(id, alert)
        guard findingActivity[key] != .running else { return nil }
        guard let node = node(withID: id), let pulse = pulse(for: node) else {
            let error = WsError.disconnected
            findingActivity[key] = .failed("\(node(withID: id)?.displayName ?? "The node") isn't connected.")
            return error
        }
        findingActivity[key] = .running
        let refusal = await pulse.perform(action, findingClass: alert.code, subject: alert.subject)
        if let refusal {
            findingActivity[key] = .failed(refusal.message)
        } else {
            findingActivity[key] = nil
            // Dealt with: what was told about it goes, and the item and notifications are judged again.
            if action != .turnBackOn {
                for notification in FleetNotifier.notificationIDs(for: alert, on: id) {
                    NotificationHub.shared.withdraw(id: notification)
                }
            }
            fleet.evaluateSoon()
        }
        return refusal
    }

    func findingActivity(for alert: NodeDigest.Alert, on id: NodeID) -> FindingActivity? {
        findingActivity[FindingActivity.key(id, alert)]
    }

    /// Opens what a remedy names, in the main window: the node's Health page and panel, or its Cost section.
    func open(_ remedy: HealthFindings.Remedy, of alert: NodeDigest.Alert, on id: NodeID) {
        guard let href = remedy.href, let route = HealthRoute(remedy: href) else { return }
        selectNode(id, section: .overview)
        switch route {
        case .health(let page, let anchor):
            openHealth(page, anchor: anchor, code: alert.code, metricKey: alert.metricKey)
        case .section(let section):
            select(section)
        }
    }
}

extension NodeDigest.Alert {
    /// The remedies this build can follow: those that open a place it has. A command remedy is not run here.
    var openableRemedies: [HealthFindings.Remedy] {
        remedies.filter { $0.href.flatMap(HealthRoute.init(remedy:)) != nil }
    }

    /// A silence set for a class that isn't active now, as a row of the Silenced list.
    init(silence mark: HealthFindings.Mark, title: String?, canManage: Bool) {
        self.init(code: mark.findingClass, subject: mark.subject, severity: mark.severity, cardID: "",
                  title: title ?? mark.findingClass, message: "Not active now.", state: mark.state, mark: mark,
                  canManage: canManage)
    }
}

/// How a finding's state reads: who acknowledged or silenced it, and until when.
nonisolated enum FindingWording {
    /// "Acknowledged by cooper, 12 min ago" or "Silenced by admin until 9:40 tomorrow"; nil while active.
    static func state(_ alert: NodeDigest.Alert, now: Date = .now) -> String? {
        guard alert.state != .active else { return nil }
        let who = alert.mark.map { $0.setByName.isEmpty ? "" : " by \($0.setByName)" } ?? ""
        switch alert.state {
        case .active:
            return nil
        case .acknowledged:
            let when = alert.mark.map { ", \(Format.relative($0.setAt, now: now))" } ?? ""
            return "Acknowledged\(who)\(when)"
        case .silenced:
            return "Silenced\(who) \(until(alert.mark?.expiresAt, now: now))"
        }
    }

    /// "until 9:40 PM", "until Dec 2, 9:40 AM", "until turned back on".
    static func until(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "until turned back on" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return "until \(date.formatted(date: .omitted, time: .shortened))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "until \(date.formatted(date: .omitted, time: .shortened)) tomorrow"
        }
        return "until \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }

    static func symbol(_ state: HealthFindings.State) -> String {
        switch state {
        case .active: "exclamationmark.circle"
        case .acknowledged: "checkmark.circle"
        case .silenced: "bell.slash"
        }
    }
}

/// The state of a finding in one quiet line, or why the last action was refused. Nothing while active.
struct FindingStateLine: View {
    var alert: NodeDigest.Alert
    var node: NodeID?

    @Environment(AppModel.self) private var model

    var body: some View {
        if let node, case .failed(let message)? = model.findingActivity(for: alert, on: node) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(StatusTone.danger.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if let text = FindingWording.state(alert) {
            Label(text, systemImage: FindingWording.symbol(alert.state))
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .lineLimit(1)
                .labelStyle(FindingLabelStyle())
        }
    }
}

/// A caption label with a small symbol, tighter than the default.
private struct FindingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The finding's menu: the remedies that open a place, then, for an account that may, Acknowledge, Silence and Turn
/// Back On. Nothing at all when there is nothing to offer; a spinner while an action runs.
struct FindingActionsMenu: View {
    var alert: NodeDigest.Alert
    var node: NodeID
    /// Wraps a remedy's navigation: the panel brings the main window forward after it.
    var opening: (() -> Void) -> Void = { $0() }

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let remedies = alert.openableRemedies
        if model.findingActivity(for: alert, on: node) == .running {
            ProgressView().controlSize(.small).frame(width: 18)
        } else if !remedies.isEmpty || alert.canManage {
            Menu {
                ForEach(remedies) { remedy in
                    Button(remedy.label, systemImage: "arrow.forward.circle") {
                        opening { model.open(remedy, of: alert, on: node) }
                    }
                }
                if alert.canManage {
                    if !remedies.isEmpty { Divider() }
                    FindingActionItems(alert: alert, node: node)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(hovering ? Color.fgMuted : Color.fgFaint)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .help(alert.canManage ? "Acknowledge, silence or open \(alert.title)" : "Open \(alert.title)")
            .accessibilityLabel("Actions for \(alert.title)")
        }
    }
}

/// Acknowledge, the Silence choices and Turn Back On, as menu items, for what the finding's state allows.
struct FindingActionItems: View {
    var alert: NodeDigest.Alert
    var node: NodeID

    @Environment(AppModel.self) private var model

    var body: some View {
        if alert.state == .active {
            Button("Acknowledge", systemImage: "checkmark.circle") { run(.acknowledge) }
        }
        if alert.state != .silenced {
            Menu("Silence", systemImage: "bell.slash") {
                ForEach(SilenceDuration.allCases) { duration in
                    Button(duration.title) { run(.silence(duration)) }
                }
            }
        }
        if alert.state != .active {
            Button("Turn Back On", systemImage: "bell") { run(.turnBackOn) }
        }
    }

    private func run(_ action: HealthFindingAction) {
        Task { await model.act(action, on: alert, node: node) }
    }
}

/// The silenced findings across nodes (All Nodes): who silenced each, until when, and Turn Back On.
struct SilencedFindingsList: View {
    var entries: [FleetSummary.FleetAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SILENCED")
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.fgSubtle)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(entries) { entry in
                HStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.fgSubtle)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.nodeName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.fgMuted)
                                    .padding(.horizontal, 6)
                                    .frame(height: 18)
                                    .background(.surface2, in: Capsule())
                                Text(entry.alert.title)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.fgMuted)
                                    .lineLimit(1)
                                Text(Severity.text(entry.alert.severity))
                                    .font(.caption)
                                    .foregroundStyle(StatusTone(severity: entry.alert.severity).color)
                            }
                            FindingStateLine(alert: entry.alert, node: entry.node)
                        }
                        Spacer(minLength: 4)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    FindingActionsMenu(alert: entry.alert, node: entry.node)
                }
            }
        }
    }
}

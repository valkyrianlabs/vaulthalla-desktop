import SwiftUI
import VHCore
import VHNodes

/// One node on All Nodes: reachability and version, health with its top alerts, storage, vaults, S3 spend against
/// its budget, and recent activity. The card observes its own node's pulse, so it fills in as that node answers;
/// clicking it opens the node, clicking an alert or figure opens the panel it's about.
struct NodePulseCard: View {
    var node: Node
    var pulse: NodePulse?

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let status = model.status(for: node)
        VStack(alignment: .leading, spacing: 14) {
            header(status)
            if let pulse {
                PulseBody(node: node, pulse: pulse)
            } else {
                unavailable(status)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(hovering ? Color.surface2 : .surface1,
                    in: RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .strokeBorder(hovering ? Color.lineStrong : .line, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .onTapGesture { model.selectNode(node.id, section: .overview) }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityAction(named: "Open") { model.selectNode(node.id, section: .overview) }
        .task(id: pulse.map(ObjectIdentifier.init)) { await pulse?.observe() }
    }

    private func header(_ status: NodeConnectionStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(tone: status.tone, size: 9, pulse: status.isTransitional)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayName)
                    .font(.headline)
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                Text(subtitle(status))
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if pulse?.isRefreshing == true {
                ProgressView().controlSize(.mini)
            }
            StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
        }
    }

    /// "Vaulthalla 1.19.0 · protocol 1 · vh.example.com:36982", or the address while the version isn't known.
    private func subtitle(_ status: NodeConnectionStatus) -> String {
        let address = node.endpoint.description
        if let route = model.route(for: node.id), status == .online {
            let via = "\(route.endpoint.description)"
            guard let settled = model.nodeProtocol(for: node.id) else { return via }
            return "\(settled.productLabel) · \(via)"
        }
        guard let settled = model.nodeProtocol(for: node.id) else { return address }
        return "\(settled.productLabel) · \(address)"
    }

    @ViewBuilder
    private func unavailable(_ status: NodeConnectionStatus) -> some View {
        let (icon, text): (String, String) = switch status {
        case .notPaired: ("lock.laptopcomputer", "This Mac isn't paired with this node yet.")
        case .revoked: ("lock.slash", "The node no longer accepts this Mac. Pair again to manage it from here.")
        case .connecting: ("bolt.horizontal.circle", "Connecting…")
        case .offline:
            ("bolt.horizontal.circle", model.offlineReason(for: node.id).map { "Offline: \($0)" }
                ?? (model.needsPairingAgain(node.id) ? "Needs pairing again." : "Not reachable from this Mac right now."))
        case .online:
            model.incompatibility(for: node).map { ("arrow.triangle.2.circlepath", $0.message) }
                ?? ("hourglass", "Waiting for the node…")
        }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(text, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if status == .notPaired || status == .revoked || model.needsPairingAgain(node.id) {
                Button(status == .notPaired ? "Pair This Mac…" : "Pair Again…") { model.presentPairing(for: node.id) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open") { model.selectNode(node.id, section: .overview) }
        if node.pairing.isPaired {
            Divider()
            ForEach([NodeSection.vaults, .files, .syncConflicts, .cost], id: \.self) { section in
                Button(section.title, systemImage: section.systemImage) { model.selectNode(node.id, section: section) }
            }
        } else {
            Button("Pair This Mac…") { model.presentPairing(for: node.id) }
        }
        Divider()
        Button("Rename…") { model.nodePendingRename = node }
    }
}

// MARK: - Body

/// What the node reported. A part the node didn't answer says why, in place; the others still show.
private struct PulseBody: View {
    var node: Node
    var pulse: NodePulse

    @Environment(AppModel.self) private var model

    private static let alertsShown = 3

    var body: some View {
        let digest = pulse.digest
        VStack(alignment: .leading, spacing: 14) {
            if !(pulse.queries.isConnected), let at = pulse.updatedAt {
                Label("Showing data from \(at.formatted(date: .omitted, time: .shortened)); reconnecting…",
                      systemImage: "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
            health(digest)
            Divider().overlay(Color.line)
            figures(digest)
            if let activity = digest.activity.value, !activity.recent.isEmpty {
                RecentActivityList(events: Array(activity.recent.prefix(3)))
            }
        }
    }

    // MARK: Health

    @ViewBuilder
    private func health(_ digest: NodeDigest) -> some View {
        switch digest.health {
        case .value(let health):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    let tone = StatusTone(severity: health.severity)
                    Image(systemName: Severity.symbol(health.severity))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tone.color)
                        .frame(width: 30, height: 30)
                        .background(tone.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Severity.headline(health.severity))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.fg)
                        let counts = Severity.issueCount(errors: health.errorCount, warnings: health.warningCount)
                        Text(counts.isEmpty ? "Checked \(Format.relative(health.checkedAt))"
                                            : "\(counts) · checked \(Format.relative(health.checkedAt))")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                    Spacer(minLength: 0)
                }
                AreaChips(health: health, conflicts: digest.conflicts.value) { area in open(area, health: health) }
                if !health.alerts.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(health.alerts.prefix(Self.alertsShown)) { alert in
                            Button {
                                model.open(alert, on: node.id)
                            } label: {
                                NodeAlertRow(alert: alert)
                            }
                            .buttonStyle(.plain)
                        }
                        if health.alerts.count > Self.alertsShown {
                            Button("\(health.alerts.count - Self.alertsShown) more on the node's Overview") {
                                model.selectNode(node.id, section: .overview)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            .padding(.leading, 34)
                            .padding(.top, 2)
                        }
                    }
                }
            }
        case let other:
            PartLine(part: other, subject: "health", systemImage: "waveform.path.ecg")
        }
    }

    /// An area chip opens the panel behind it: sync goes to Sync Conflicts, the rest to the Overview's card.
    private func open(_ area: NodeDigest.Area, health: NodeDigest.Health) {
        if area == .sync {
            model.selectNode(node.id, section: .syncConflicts)
            return
        }
        if let alert = health.alerts.first(where: { $0.area == area }) {
            model.open(alert, on: node.id)
            return
        }
        model.healthFocus = AreaChips.cardID[area]
        model.selectNode(node.id, section: .overview)
    }

    // MARK: Figures

    private func figures(_ digest: NodeDigest) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
                FigureCell(label: "Storage", section: .vaults, node: node) { storage(digest.storage) }
                FigureCell(label: "Vaults", section: .vaults, node: node) { vaults(digest) }
            }
            GridRow {
                FigureCell(label: "S3 spend", section: .cost, node: node) { cost(digest.cost) }
                FigureCell(label: "Activity", section: .files, node: node) { activity(digest.activity) }
            }
        }
    }

    @ViewBuilder
    private func storage(_ part: NodeDigest.Part<NodeDigest.Storage>) -> some View {
        if let storage = part.value {
            FigureValue(Format.bytes(storage.usedBytes))
            if let fraction = storage.fractionUsed, let quota = storage.quotaBytes {
                FleetMeter(fraction: fraction)
                FigureHint("\(fraction.formatted(.percent.precision(.fractionLength(0)))) of \(Format.bytes(quota)) quota")
            } else if storage.unlimitedVaultCount > 0 {
                FigureHint(storage.unlimitedVaultCount == storage.activeVaultCount
                           ? "No vault quotas" : "\(storage.unlimitedVaultCount) vaults without a quota")
            }
        } else {
            PartHint(part: part)
        }
    }

    @ViewBuilder
    private func vaults(_ digest: NodeDigest) -> some View {
        if let storage = digest.storage.value {
            FigureValue(storage.vaultCount.formatted(),
                        tone: storage.errorVaultCount > 0 ? .danger : storage.degradedVaultCount > 0 ? .warn : nil)
            let problems = [
                storage.errorVaultCount > 0 ? "\(storage.errorVaultCount) in error" : nil,
                storage.degradedVaultCount > 0 ? "\(storage.degradedVaultCount) degraded" : nil,
                digest.conflicts.value.flatMap { $0 > 0 ? "\($0) sync conflict\($0 == 1 ? "" : "s")" : nil },
            ].compactMap(\.self)
            FigureHint(problems.isEmpty ? "\(storage.activeVaultCount) active" : problems.joined(separator: " · "))
        } else {
            PartHint(part: digest.storage)
        }
    }

    @ViewBuilder
    private func cost(_ part: NodeDigest.Part<NodeDigest.Cost>) -> some View {
        if let cost = part.value {
            if !cost.isTracked {
                FigureValue("—")
                FigureHint("No S3 budgets")
            } else if let window = cost.window {
                FigureValue(CostFormat.money(window.spent, cost.currency) ?? CostFormat.notEstimated,
                            tone: window.fractionUsed >= 1 ? .danger : window.fractionUsed >= 0.9 ? .warn : nil)
                FleetMeter(fraction: window.fractionUsed)
                FigureHint("of \(CostFormat.money(window.limit, cost.currency) ?? "—") \(CostFormat.window(window.windowType).lowercased()) · \(CostFormat.scope(window.scope).lowercased())")
            } else {
                FigureValue(CostFormat.money(cost.monthToDate, cost.currency) ?? CostFormat.notEstimated)
                FigureHint(cost.projectedMonth.flatMap { CostFormat.money($0, cost.currency) }
                    .map { "This month · projected \($0)" } ?? "This month · no spend limit")
            }
            if cost.blockedSyncs24h > 0 || cost.criticalAlerts > 0 {
                Label(cost.blockedSyncs24h > 0
                          ? "\(cost.blockedSyncs24h) sync\(cost.blockedSyncs24h == 1 ? "" : "s") blocked (24 h)"
                          : "\(cost.criticalAlerts) critical budget alert\(cost.criticalAlerts == 1 ? "" : "s")",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(StatusTone.danger.color)
            }
        } else {
            PartHint(part: part)
        }
    }

    @ViewBuilder
    private func activity(_ part: NodeDigest.Part<NodeDigest.Activity>) -> some View {
        if let activity = part.value {
            FigureValue("\(activity.changes24h.formatted()) change\(activity.changes24h == 1 ? "" : "s")")
            if let at = activity.lastActivityAt {
                FigureHint("Last \(Format.relative(at))\(activity.lastVault.map { " in \($0)" } ?? "")")
            } else {
                FigureHint(activity.vaultsAsked == 0 ? "No vaults" : "Nothing recent")
            }
            if activity.vaultsCounted < activity.vaultsAsked {
                FigureHint("From \(activity.vaultsCounted) of \(activity.vaultsAsked) vaults")
            }
        } else {
            PartHint(part: part)
        }
    }
}

// MARK: - Pieces

/// FUSE, Database, Storage and Sync, each with the worst severity the node reports for it.
private struct AreaChips: View {
    var health: NodeDigest.Health
    var conflicts: Int64?
    var open: (NodeDigest.Area) -> Void

    /// The overview card each area's chip brings forward.
    static let cardID: [NodeDigest.Area: String] = [
        .fuse: "system.fuse", .database: "system.db", .storage: "system.storage", .sync: "system.retention",
    ]

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(NodeDigest.Area.watched, id: \.self) { area in
                let (tone, detail) = state(area)
                Button {
                    open(area)
                } label: {
                    HStack(spacing: 5) {
                        StatusDot(tone: tone, size: 6)
                        Text(area.title)
                            .foregroundStyle(.fgMuted)
                        if let detail {
                            Text(detail)
                                .foregroundStyle(tone.color)
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(.surface1, in: Capsule())
                    .overlay { Capsule().strokeBorder(.line, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .help("\(area.title): \(detail ?? Severity.text(severity(area) ?? "unknown"))")
            }
        }
    }

    private func severity(_ area: NodeDigest.Area) -> String? {
        let alerted = health.alerts.filter { $0.area == area }.map(\.severity)
        let reported = [health.areas[area]].compactMap(\.self)
        return (alerted + reported).min { SeverityRank.of($0) < SeverityRank.of($1) }
    }

    private func state(_ area: NodeDigest.Area) -> (StatusTone, String?) {
        if area == .sync, let conflicts {
            let alerted = severity(.sync)
            if conflicts > 0 { return (.warn, "\(conflicts)") }
            return (alerted.map(StatusTone.init(severity:)) ?? .ok, nil)
        }
        guard let severity = severity(area) else { return (.unknown, nil) }
        return (StatusTone(severity: severity), nil)
    }
}

/// A figure with its label; clicking it opens the section behind it.
private struct FigureCell<Content: View>: View {
    var label: String
    var section: NodeSection
    var node: Node
    @ViewBuilder var content: Content

    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.selectNode(node.id, section: section)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.caption2.weight(.medium))
                    .tracking(0.6)
                    .foregroundStyle(.fgSubtle)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(section.title)")
    }
}

private struct FigureValue: View {
    var text: String
    var tone: StatusTone?

    init(_ text: String, tone: StatusTone? = nil) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tone?.color ?? .fg)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct FigureHint: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.fgSubtle)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Why a figure isn't there, in a few words.
private struct PartHint<Value: Sendable & Hashable>: View {
    var part: NodeDigest.Part<Value>

    var body: some View {
        switch part {
        case .loading:
            ProgressView().controlSize(.mini).frame(height: 20)
        case .denied:
            Label("No access", systemImage: "lock").font(.callout).foregroundStyle(.fgFaint)
        case .unsupported:
            Text("Not on this version").font(.callout).foregroundStyle(.fgFaint)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.fgFaint).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .value:
            EmptyView()
        }
    }
}

/// A whole part (health) that isn't there, as a line.
private struct PartLine<Value: Sendable & Hashable>: View {
    var part: NodeDigest.Part<Value>
    var subject: String
    var systemImage: String

    var body: some View {
        let text: String = switch part {
        case .loading: "Checking \(subject)…"
        case .denied: "This account can't see \(subject) (needs admin.stats.view)."
        case .unsupported: "This node's Vaulthalla doesn't report \(subject)."
        case .failed(let message): "Couldn't load \(subject): \(message)"
        case .value: ""
        }
        HStack(spacing: 8) {
            if case .loading = part {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: { if case .denied = part { "lock" } else { systemImage } }())
                    .foregroundStyle(.fgFaint)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The latest events across the node's vaults.
private struct RecentActivityList: View {
    var events: [NodeDigest.Activity.Event]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("RECENT")
                .font(.caption2.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(.fgSubtle)
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(event.action))
                        .foregroundStyle(event.failed ? StatusTone.danger.color : Color.accentText)
                        .frame(width: 14)
                    Text(Self.file(event.path))
                        .foregroundStyle(.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(event.vault)
                        .foregroundStyle(.fgFaint)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.relative(event.at))
                        .foregroundStyle(.fgFaint)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.caption)
                .help("\(Format.words(event.action)) \(event.path)\(event.user.map { " by \($0)" } ?? "")")
            }
        }
    }

    private static func file(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.isEmpty ? "/" : name
    }

    private static func symbol(_ action: String) -> String {
        switch action.lowercased() {
        case let a where a.contains("upload") || a.contains("create") || a.contains("write"): "arrow.up.circle"
        case let a where a.contains("delete") || a.contains("remove") || a.contains("trash"): "trash"
        case let a where a.contains("rename") || a.contains("move"): "arrow.right.circle"
        case let a where a.contains("copy"): "doc.on.doc"
        case let a where a.contains("restore"): "arrow.uturn.backward.circle"
        case let a where a.contains("download") || a.contains("read"): "arrow.down.circle"
        default: "circle"
        }
    }
}

/// How full a quota or budget is: accent, amber from 90 %, red past it.
struct FleetMeter: View {
    var fraction: Double

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(.surface3)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(fraction > 1 ? StatusTone.danger.color : fraction >= 0.9 ? StatusTone.warn.color : Color.accentFill)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

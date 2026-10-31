import SwiftUI
import VHCore
import VHNodes

/// How this Mac reaches the node right now (the server's transfer protocol, "Phase 7"): the route class, the endpoint,
/// the verified server key, the round trip, what transfers report, and, when a better route wasn't used, why. No
/// credentials or session material: endpoints, classes, timings and outcomes only.
struct ConnectionPanel: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        let route = model.route(for: node.id)
        Panel(title: "Connection", subtitle: subtitle(route)) {
            VStack(alignment: .leading, spacing: 16) {
                StatGrid {
                    StatTile(label: "Route", value: route.map { ConnectionWords.routeLabel($0) },
                             systemImage: route.map { ConnectionWords.symbol(for: $0.transportClass) } ?? "network",
                             hint: route.map { ConnectionWords.routeHint($0) }, tone: route.map(ConnectionWords.tone))
                    StatTile(label: "Round trip", value: route?.rtt.map(ConnectionWords.milliseconds) ?? "—",
                             systemImage: "stopwatch", hint: "TLS handshake to the endpoint")
                    StatTile(label: "Upload", value: ConnectionWords.rate(stats?.throughputUp ?? testUpload),
                             systemImage: "arrow.up.circle", hint: rateHint(stats?.throughputUp, measured: testUpload))
                    StatTile(label: "Download", value: ConnectionWords.rate(stats?.throughputDown ?? testDownload),
                             systemImage: "arrow.down.circle", hint: rateHint(stats?.throughputDown, measured: testDownload))
                }
                DefinitionList(items: details(route), monospacedValues: ["Endpoint", "Address reached"], termWidth: 130)
                Toggle(isOn: tuning) {
                    Text("Automatic tuning")
                    Text("Adapts the part size and the parts sent at once to the measured link. Off, uploads send "
                         + "64 MiB parts, two at a time.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                if let route, let selection = route.selection {
                    WhyNotBetter(route: route, selection: selection)
                }
                if case .finished(let result)? = model.connectionTests[node.id], let note = result.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                }
            }
        } actions: {
            HStack(spacing: 8) {
                if model.connectionTests[node.id] == .running {
                    ProgressView().controlSize(.small)
                }
                Button("Test Connection") { model.testConnection(for: node.id) }
                    .controlSize(.small)
                    .disabled(!model.canTestConnection(for: node.id))
                    .help("Probe every address of the node again, use the best one that proves its key, and measure "
                          + "throughput both ways where the node serves the calibration lanes")
            }
        }
    }

    private var stats: TransferStats? { model.transferStats[node.id] }

    private var tuning: Binding<Bool> {
        Binding(get: { model.automaticTuning(for: node.id) },
                set: { model.setAutomaticTuning($0, for: node.id) })
    }

    private var testResult: ConnectionTestResult? {
        if case .finished(let result)? = model.connectionTests[node.id] { return result }
        return nil
    }

    /// Where a rate comes from: transfers in progress, the last test, or nothing yet.
    private func rateHint(_ reported: Double?, measured: Double?) -> String {
        if reported != nil { return "recent transfers" }
        return measured != nil ? "measured by the test" : "no transfers yet"
    }

    private var testUpload: Double? { testResult?.uploadBytesPerSecond }
    private var testDownload: Double? { testResult?.downloadBytesPerSecond }

    private func subtitle(_ route: NodeRoute?) -> String {
        guard let route else { return "How this Mac reaches the node. Nothing here is secret." }
        if !route.isConnected { return "Connecting over the route below." }
        return "Connected to \(node.displayName). Nothing here is secret."
    }

    private func details(_ route: NodeRoute?) -> [(term: String, value: String)] {
        var items: [(term: String, value: String)] = [("Server", serverLine)]
        guard let route else {
            items.append(("Endpoint", "—"))
            items.append(("Identity", "—"))
            return items + transferItems
        }
        items.append(("Endpoint", route.endpoint.description))
        if let address = route.remoteAddress {
            items.append(("Address reached", route.interfaceName.map { "\(address) via \($0)" } ?? address))
        }
        items.append(("Identity", ConnectionWords.identity(route.verifiedKey)))
        items += transferItems
        if let at = route.selection?.startedAt {
            items.append(("Last checked", at.formatted(.relative(presentation: .named))))
        }
        return items
    }

    private var serverLine: String {
        guard let id = node.serverNodeID else { return node.displayName }
        return "\(node.displayName) (\(id.count > 16 ? "\(id.prefix(12))…" : id))"
    }

    private var transferItems: [(term: String, value: String)] {
        var items: [(term: String, value: String)] = [
            ("Part size", stats?.partBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "—"),
            ("Parts in flight", ConnectionWords.parts(inFlight: stats?.partsInFlight, allowed: stats?.concurrency)),
        ]
        if let stats {
            if let source = stats.source { items.append(("Tuned from", ConnectionWords.source(source))) }
            if let serverBound = stats.serverBound {
                items.append(("Limited by", serverBound ? "the server's disk" : "the network"))
            }
        }
        return items
    }
}

/// When a route of a better class than the one in use didn't work: why, in plain words, with every candidate's
/// technical outcome behind a disclosure.
private struct WhyNotBetter: View {
    var route: NodeRoute
    var selection: EndpointSelection

    @State private var showsDetails = false

    var body: some View {
        let missed = route.isFallback
            ? selection.reports.filter { $0.outcome != .notTried && $0.candidate.sources != [.loopback] }
            : selection.betterRoutesNotUsed
        VStack(alignment: .leading, spacing: 8) {
            if !missed.isEmpty {
                Callout(tone: route.isFallback ? .warn : .info, systemImage: "arrow.triangle.branch") {
                    Text(route.isFallback ? "No address proved the server's key"
                         : "A better route wasn't used")
                        .fontWeight(.semibold)
                        .foregroundStyle(.fg)
                    ForEach(Array(missed.prefix(4).enumerated()), id: \.offset) { _, report in
                        Text("\(report.transportClass.displayName) \(report.candidate.endpoint.description): "
                             + ConnectionWords.plain(report.outcome))
                            .foregroundStyle(.fgMuted)
                    }
                    if missed.count > 4 {
                        Text("and \(missed.count - 4) more")
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }
            DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(selection.reports.enumerated()), id: \.offset) { _, report in
                        Text(ConnectionWords.technical(report, active: report.candidate.endpoint == route.endpoint))
                            .font(.caption.monospaced())
                            .foregroundStyle(.fgMuted)
                            .textSelection(.enabled)
                    }
                    if selection.usedBonjour {
                        Text("Bonjour was browsed as the last source.")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
            .foregroundStyle(.fgSubtle)
        }
    }
}

/// The words and symbols of the connection view.
enum ConnectionWords {
    static func routeLabel(_ route: NodeRoute) -> String {
        route.isFallback ? "Unverified" : route.transportClass.displayName
    }

    static func routeHint(_ route: NodeRoute) -> String {
        if route.isFallback { return "the address you entered" }
        return route.isConnected ? "connected" : "connecting"
    }

    /// Green only for a connected, verified route; never for an unknown one.
    static func tone(_ route: NodeRoute) -> StatusTone {
        guard route.isConnected else { return .info }
        return route.isFallback ? .warn : .ok
    }

    static func symbol(for transportClass: EndpointClass) -> String {
        switch transportClass {
        case .loopback: "desktopcomputer"
        case .lan: "wifi.router"
        case .vpn: "lock.shield"
        case .wan: "globe"
        case .passthrough: "arrow.left.arrow.right.circle"
        }
    }

    static func identity(_ key: NodeRoute.VerifiedKey) -> String {
        switch key {
        case .current: "Verified: the pinned server key"
        case .next: "Verified: the node's announced next key"
        case .unverified: "Not proven by a probe; the connection still pins the server key"
        }
    }

    static func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }

    /// "2 of 4 allowed", "2", or "—".
    static func parts(inFlight: Int?, allowed: Int?) -> String {
        guard let inFlight else { return "—" }
        guard let allowed else { return String(inFlight) }
        return "\(inFlight) of \(allowed) allowed"
    }

    static func source(_ source: TransferStats.EstimateSource) -> String {
        switch source {
        case .defaults: "starting values (nothing measured yet)"
        case .cached: "the last transfer over this kind of route"
        case .calibrated: "a calibration"
        case .measured: "this transfer's parts"
        }
    }

    /// "12.4 MB/s", or "—" when nothing reported it.
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .decimal) + "/s"
    }

    static func plain(_ outcome: EndpointSelection.Outcome) -> String {
        switch outcome {
        case .ok: "works"
        case .refused: "nothing is listening there"
        case .timeout: "no answer in time"
        case .identityMismatch: "a different server answered there"
        case .tlsError: "the secure connection failed"
        case .unresolved: "the name doesn't resolve from this Mac"
        case .notTried: "not tried"
        }
    }

    /// One candidate, as a log line: endpoint, sources, class, outcome, RTT, address.
    static func technical(_ report: EndpointSelection.Report, active: Bool) -> String {
        var parts = [
            (active ? "▸ " : "  ") + report.candidate.endpoint.description,
            report.candidate.sources.map(\.rawValue).joined(separator: "+"),
            report.transportClass.rawValue,
            outcomeCode(report.outcome),
        ]
        if let rtt = report.rtt { parts.append(milliseconds(rtt)) }
        if let address = report.remoteAddress { parts.append("→ \(address)\(report.interfaceName.map { "%\($0)" } ?? "")") }
        return parts.joined(separator: "  ")
    }

    static func outcomeCode(_ outcome: EndpointSelection.Outcome) -> String {
        switch outcome {
        case .ok: "ok"
        case .refused: "refused"
        case .timeout: "timeout"
        case .identityMismatch: "identity_mismatch"
        case .tlsError(let text): "tls_error(\(text))"
        case .unresolved: "unresolved"
        case .notTried: "not_tried"
        }
    }
}

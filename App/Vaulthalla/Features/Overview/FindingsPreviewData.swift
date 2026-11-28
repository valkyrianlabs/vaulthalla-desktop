#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHTransport

/// PREVIEW DATA for acting on findings: "Home lab"'s three warnings (the overview's attention list), one still
/// active, one acknowledged and one silenced for the rest of the day, and a silence on a class that isn't active.
/// Acknowledge, silence and turn back on change it, as the server would.
///
/// `-VHDebugFindingsManage NO` answers as an account without `admin.stats.manage` (no actions, refused if sent);
/// `-VHDebugFindingsOlder YES` (in `PreviewSamples`) makes "Home lab" a Vaulthalla without the findings commands.
nonisolated enum FindingsPreviewData: PreviewFeature {
    private static let now = PreviewData.now

    /// (class, notifies, title, remedy label, remedy route) for each class the preview knows.
    private static let catalog: [String: (notifies: Bool, title: String, label: String, href: String)] = [
        "system.fuse.error_rate_elevated": (true, "Filesystem errors are elevated", "Open the filesystem",
                                            "/health/filesystem#fuse"),
        "system.storage.degraded_vaults": (true, "A vault's storage is degraded", "Open storage",
                                           "/health/storage#storage-backend"),
        "system.pricing.warnings": (true, "Budget warnings are waiting", "Review cost alerts", "/cost#budget-alerts"),
        "system.operations.active_work": (false, "Work is queued or running", "Open the operation queue",
                                          "/health/activity#operation-queue"),
    ]

    private static let marks = Mutex<[String: WsModel.HealthFindingMark]>([
        "system.storage.degraded_vaults": .init(
            class: "system.storage.degraded_vaults", subject: "", state: "acknowledged", severity: "warning", setBy: 1,
            setByName: "cooper", setAt: now - 25 * 60, note: "Offsite bucket is rebuilding; checking tonight."),
        "system.pricing.warnings": .init(
            class: "system.pricing.warnings", subject: "", state: "silenced", severity: "warning", setBy: 2,
            setByName: "admin", setAt: now - 2 * 3_600, expiresAt: now + 22 * 3_600),
        "system.operations.active_work": .init(
            class: "system.operations.active_work", subject: "", state: "silenced", severity: "warning", setBy: 1,
            setByName: "cooper", setAt: now - 3 * 86_400),
    ])

    private static var canManage: Bool {
        UserDefaults.standard.object(forKey: "VHDebugFindingsManage") == nil
            || UserDefaults.standard.bool(forKey: "VHDebugFindingsManage")
    }

    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any? {
        let refused = WsError.denied("Needs the \"manage stats\" admin permission (admin.stats.manage).")
        switch command {
        case .healthFindingsList:
            guard transport.scenario == .full else { throw .denied("Needs the \"view stats\" admin permission.") }
            let catalog = (payload as? Ws.Health.Findings.List.Payload)?.includeCatalog == true
            return Ws.Health.Findings.List.Response(health: snapshot(catalog: catalog))
        case .healthFindingAcknowledge:
            guard canManage else { throw refused }
            let ask = payload as? Ws.Health.Finding.Acknowledge.Payload
            guard let code = ask?.class, isActive(code) else { throw .conflict("That finding isn't active now.") }
            mark(code, "acknowledged", until: nil)
            return Ws.Health.Finding.Acknowledge.Response(health: snapshot(catalog: false))
        case .healthFindingSilence:
            guard canManage else { throw refused }
            let ask = payload as? Ws.Health.Finding.Silence.Payload
            guard let code = ask?.class else { throw .invalid("Bad payload.") }
            mark(code, "silenced", until: ask?.forSeconds?.wrapped.map { now + $0 })
            return Ws.Health.Finding.Silence.Response(health: snapshot(catalog: false))
        case .healthFindingUnsilence:
            guard canManage else { throw refused }
            let code = (payload as? Ws.Health.Finding.Unsilence.Payload)?.class ?? ""
            guard marks.withLock({ $0.removeValue(forKey: code) }) != nil else {
                throw .notFound("It is neither acknowledged nor silenced.")
            }
            return Ws.Health.Finding.Unsilence.Response(health: snapshot(catalog: false))
        default:
            return nil
        }
    }

    private static func isActive(_ code: String) -> Bool {
        PreviewData.overview.attention.contains { $0.code == code }
    }

    private static func mark(_ code: String, _ state: String, until: Int64?) {
        marks.withLock {
            $0[code] = .init(class: code, subject: "", state: state, severity: "warning", setBy: 1,
                             setByName: "cooper", setAt: Int64(Date.now.timeIntervalSince1970), expiresAt: until)
        }
    }

    private static func snapshot(catalog withCatalog: Bool) -> WsModel.HealthFindings {
        let overview = PreviewData.overview
        let marks = marks.withLock { $0 }
        let findings = overview.attention.map { item in
            let known = catalog[item.code]
            let mark = marks[item.code]
            return WsModel.HealthFinding(
                class: item.code, subject: "", cardID: item.cardID, severity: item.severity, title: item.title,
                classTitle: known?.title ?? item.title, message: item.message, href: item.href,
                metricKey: item.metricKey, notifies: known?.notifies ?? true, state: mark?.state ?? "active",
                mark: mark,
                remedies: known.map { [.init(id: "open", label: $0.label, kind: "open", href: $0.href)] } ?? [])
        }
        let active = findings.filter { $0.state == "active" }
        let codes = Set(findings.map(\.class))
        return WsModel.HealthFindings(
            overallStatus: overview.overallStatus, errorCount: overview.errorCount, warningCount: overview.warningCount,
            unattendedErrorCount: Int64(active.filter { $0.severity == "error" }.count),
            unattendedWarningCount: Int64(active.filter { $0.severity == "warning" }.count),
            checkedAt: now - 20, findings: findings,
            silences: marks.values.filter { !codes.contains($0.class) && $0.state == "silenced" }
                .sorted { $0.class < $1.class },
            canManage: canManage,
            catalog: withCatalog ? catalog.map {
                .init(class: $0.key, cardID: "", title: $0.value.title, maxSeverity: "warning",
                      notifies: $0.value.notifies,
                      remedies: [.init(id: "open", label: $0.value.label, kind: "open", href: $0.value.href)])
            } : nil)
    }
}
#endif

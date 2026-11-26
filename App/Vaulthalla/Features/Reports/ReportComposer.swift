import Foundation
import OSLog
import VHCore
import VHNodes
import VHReports

/// What a report is about, as the place that started it knows it (docs/mac-experience.md §8).
struct ReportRequest: Identifiable, Hashable {
    enum Origin: Hashable {
        /// A health finding of a node.
        case finding(NodeID, NodeDigest.Alert)
        /// A node, nothing more specific.
        case node(NodeID)
        /// Help ▸ Report a Problem.
        case general
    }

    let id = UUID()
    var origin: Origin
}

/// Gathers the facts a report is built from: only what the app already shows, chosen field by field. Names are
/// collected here so the redactor can replace them; nothing is read from a node for the report's sake.
enum ReportComposer {
    /// How far back this app's own log lines go.
    static let logWindow: TimeInterval = 15 * 60

    static func input(for request: ReportRequest, model: AppModel, note: String?) -> ReportBuilder.Input {
        var subject = ReportBuilder.Subject(kind: .general)
        var node: Node?
        switch request.origin {
        case .finding(let id, let alert):
            node = model.node(withID: id)
            subject = .init(kind: .finding, class: alert.code, severity: alert.severity, card: alert.cardID,
                            title: alert.title, message: alert.message)
        case .node(let id):
            node = model.node(withID: id)
        case .general:
            break
        }
        return ReportBuilder.Input(subject: subject, node: node.map { facts(for: $0, model: model) },
                                   desktop: desktopFacts(model), log: recentLog(), note: note, known: knownNames(model))
    }

    private static func facts(for node: Node, model: AppModel) -> ReportBuilder.NodeFacts {
        let settled = model.nodeProtocol(for: node.id)
        let route = model.route(for: node.id)
        let health = model.pulse(for: node)?.digest.health.value
        var hosts = [node.endpoint.host] + node.endpoints.map(\.host)
        if let remote = route?.remoteAddress { hosts.append(remote) }
        var ids = [node.id.rawValue]
        if let server = node.serverNodeID { ids.append(server) }
        if case .paired(_, let deviceID, _) = node.pairing { ids.append(deviceID) }
        return ReportBuilder.NodeFacts(
            name: node.displayName, hosts: hosts, ids: ids, version: settled?.serverVersion,
            protocol: settled?.version, protocolRange: settled?.serverRange,
            routeClass: route.map { String(describing: $0.transportClass) },
            reachability: model.status(for: node).label.lowercased(),
            overallStatus: health?.severity, errorCount: health.map { Int($0.errorCount) },
            warningCount: health.map { Int($0.warningCount) },
            checkedAt: health.map { Int64($0.checkedAt.timeIntervalSince1970) },
            findings: (health?.alerts ?? []).map {
                .init(class: $0.code, severity: $0.severity, card: $0.cardID, message: $0.message)
            })
    }

    private static func desktopFacts(_ model: AppModel) -> ReportBuilder.DesktopFacts {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var settings: [String: String] = [
            "menu_bar_item": MenuBarPreferences.showsItem ? "on" : "off",
            "open_at_login": String(describing: model.loginItem.status),
            "notifications": model.fleet.settings.enabled ? "on" : "off",
            "notification_permission": String(describing: NotificationHub.shared.permission),
            "credential_role": model.isCredentialOwner ? "owner" : "consumer",
        ]
        for notice in FleetNotice.allCases {
            settings["notify." + notice.rawValue] = model.fleet.settings.isOn(notice) ? "on" : "off"
        }
        return ReportBuilder.DesktopFacts(
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", arch: machine("hw.machine"),
            model: machine("hw.model"), nodeCount: model.nodes.count,
            linkedToCloud: model.cloud?.canSendReports ?? false, settings: settings)
    }

    /// Every name this Mac knows that a message or a log line might mention.
    private static func knownNames(_ model: AppModel) -> ReportBuilder.KnownNames {
        var known = ReportBuilder.KnownNames()
        for node in model.nodes {
            known.nodes.append(node.displayName)
            known.hosts.append(node.endpoint.host)
            known.hosts += node.endpoints.map(\.host)
            known.ids.append(node.id.rawValue)
            if let server = node.serverNodeID { known.ids.append(server) }
            if let storage = model.pulse(for: node)?.digest.storage.value {
                known.vaults += storage.vaults.map(\.name)
            }
        }
        known.users.append(NSUserName())
        known.users.append(NSFullUserName())
        if let host = Host.current().localizedName { known.devices.append(host) }
        return known
    }

    /// This app's own log lines of the last quarter hour, oldest first. Empty when the log store can't be read.
    private static func recentLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let since = store.position(date: Date.now.addingTimeInterval(-logWindow))
        let ours = NSPredicate(format: "subsystem == %@", "sh.vaulthalla.app")
        guard let entries = try? store.getEntries(at: since, matching: ours) else { return [] }
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        return entries.compactMap { $0 as? OSLogEntryLog }.suffix(2000).map {
            "\($0.date.formatted(time)) \($0.category) \($0.composedMessage)"
        }
    }

    private static func machine(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

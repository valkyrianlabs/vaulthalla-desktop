import AppKit
import Foundation
import Observation
import UserNotifications
import VHCore
import VHNodes

/// The one owner of the notification centre (docs/mac-experience.md §6): its delegate, the categories, permission,
/// and where a click goes. Everything Vaulthalla notifies about is posted through it. A finding's notification, for
/// an account that may, carries Acknowledge and Silence for a Day: the person's click runs the same server command
/// as the panel's menu, and a refusal comes back as a follow-up notification.
@Observable
final class NotificationHub: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHub()

    enum Permission: Hashable {
        /// Not read yet, or this process has no bundle (tests, previews).
        case unknown
        case notAsked
        case allowed
        /// Turned off in System Settings.
        case denied
    }

    /// Where a click on a notification goes.
    enum Route: Hashable, Sendable {
        case node(NodeID)
        case pairAgain(NodeID)
        case finding(NodeID, NodeDigest.Alert)
        case syncConflicts(NodeID)
        case recoveryKeys
        case update
    }

    nonisolated static let fleetCategory = "sh.vaulthalla.fleet"
    nonisolated static let recoveryKeysCategory = "sh.vaulthalla.recovery-keys"
    nonisolated static let updateCategory = "sh.vaulthalla.update"
    nonisolated static let openAction = "open"
    nonisolated static let findingCategory = "sh.vaulthalla.fleet.finding"
    nonisolated static let acknowledgeAction = "finding.acknowledge"
    nonisolated static let silenceDayAction = "finding.silence-day"

    private(set) var permission: Permission = .unknown
    /// Called on the main actor when the person clicks a notification or its action.
    @ObservationIgnored var onOpen: ((Route) -> Void)?
    /// Called on the main actor when the person picks Acknowledge or Silence for a Day on a finding's notification;
    /// answers why the node refused, nil when it was done.
    @ObservationIgnored var onFindingAction: (@MainActor (HealthFindingAction, NodeID, NodeDigest.Alert) async -> String?)?
    @ObservationIgnored private var registered = false

    /// The notification centre, unless the app runs without a bundle (`swift test`, previews), where it traps.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Takes the delegate and registers the categories. Idempotent; called at launch, so a click on a notification
    /// that started the app is routed.
    func activate() {
        guard !registered, let center else { return }
        registered = true
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open Vaulthalla", options: [.foreground])
        let keys = UNNotificationAction(identifier: Self.openAction, title: "Open Recovery Keys", options: [.foreground])
        let update = UNNotificationAction(identifier: Self.openAction, title: "Show Update", options: [.foreground])
        // Changing what the server tells everyone: only with the Mac unlocked, and without bringing the app forward.
        let acknowledge = UNNotificationAction(identifier: Self.acknowledgeAction, title: "Acknowledge",
                                               options: [.authenticationRequired])
        let silence = UNNotificationAction(identifier: Self.silenceDayAction, title: "Silence for a Day",
                                           options: [.authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.fleetCategory, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.findingCategory, actions: [acknowledge, silence, open],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.recoveryKeysCategory, actions: [keys], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.updateCategory, actions: [update], intentIdentifiers: []),
        ])
        center.delegate = self
        Task { await refreshPermission() }
    }

    /// Reads what System Settings says now.
    func refreshPermission() async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        let read: Permission = switch status {
        case .notDetermined: .notAsked
        case .denied: .denied
        default: .allowed
        }
        if read != permission { permission = read }
    }

    /// Asks macOS for permission. macOS shows its prompt only the first time; afterwards this just reads the answer.
    @discardableResult
    func requestPermission() async -> Bool {
        activate()
        guard let center else { return false }
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        await refreshPermission()
        return granted
    }

    // MARK: - Posting

    func post(_ notification: FleetNotification) {
        let route: Route = switch notification.target {
        case .node(let id): .node(id)
        case .pairAgain(let id): .pairAgain(id)
        case .finding(let id, let alert): .finding(id, alert)
        case .syncConflicts(let id): .syncConflicts(id)
        }
        // The actions only where the account may use them, on one finding that nobody attended to yet.
        let actionable = if case .finding(_, let alert) = notification.target { alert.canManage && !alert.isAttended }
            else { false }
        post(id: notification.id, title: notification.title, body: notification.body, sound: notification.sound,
             category: actionable ? Self.findingCategory : Self.fleetCategory, route: route)
    }

    /// Posts (or replaces, for the same `id`) one notification. Nothing is posted without permission.
    func post(id: String, title: String, body: String, sound: Bool, category: String, route: Route) {
        activate()
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = Self.userInfo(for: route)
        content.threadIdentifier = Self.thread(for: route)
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task { try? await center.add(request) }
    }

    /// Takes a delivered notification back (the thing it was about is over).
    func withdraw(id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: - Routes on the wire (userInfo: strings only)

    private static func thread(for route: Route) -> String {
        switch route {
        case .node(let id), .pairAgain(let id), .finding(let id, _), .syncConflicts(let id): id.rawValue
        case .recoveryKeys: "recovery-keys"
        case .update: "update"
        }
    }

    nonisolated static func userInfo(for route: Route) -> [String: String] {
        switch route {
        case .node(let id): ["route": "node", "node": id.rawValue]
        case .pairAgain(let id): ["route": "pair", "node": id.rawValue]
        case .syncConflicts(let id): ["route": "conflicts", "node": id.rawValue]
        case .recoveryKeys: ["route": "keys"]
        case .update: ["route": "update"]
        case .finding(let id, let alert):
            ["route": "finding", "node": id.rawValue, "code": alert.code, "subject": alert.subject,
             "severity": alert.severity, "card": alert.cardID, "title": alert.title, "message": alert.message,
             "manage": alert.canManage ? "yes" : "no"]
        }
    }

    nonisolated static func route(from info: [String: String]) -> Route? {
        let node = info["node"].map { NodeID(rawValue: $0) }
        switch (info["route"], node) {
        case ("node", let id?): return .node(id)
        case ("pair", let id?): return .pairAgain(id)
        case ("conflicts", let id?): return .syncConflicts(id)
        case ("keys", _): return .recoveryKeys
        case ("update", _): return .update
        case ("finding", let id?):
            guard let code = info["code"], let card = info["card"] else { return .node(id) }
            return .finding(id, NodeDigest.Alert(code: code, subject: info["subject"] ?? "",
                                                 severity: info["severity"] ?? "unknown", cardID: card,
                                                 title: info["title"] ?? "", message: info["message"] ?? "",
                                                 canManage: info["manage"] == "yes"))
        default: return nil
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let content = response.notification.request.content
        var info: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        // The notification Vaulthalla posted before the hub existed carries no route.
        let route = Self.route(from: info)
            ?? (content.categoryIdentifier == Self.recoveryKeysCategory ? .recoveryKeys : nil)
        guard let route else { return }
        if case .finding(let id, let alert) = route, let action = Self.findingAction(response.actionIdentifier) {
            await perform(action, on: alert, node: id)
            return
        }
        await MainActor.run { self.onOpen?(route) }
    }

    nonisolated static func findingAction(_ identifier: String) -> HealthFindingAction? {
        switch identifier {
        case acknowledgeAction: .acknowledge
        case silenceDayAction: .silence(.day)
        default: nil
        }
    }

    /// The person picked an action on a finding's notification: the same command as the panel's menu. A refusal is
    /// told as a follow-up, which opens the finding when clicked.
    private func perform(_ action: HealthFindingAction, on alert: NodeDigest.Alert, node id: NodeID) async {
        guard let onFindingAction else { return }
        guard let refusal = await onFindingAction(action, id, alert) else { return }
        post(id: "\(id.rawValue)|finding.refused|\(alert.id)", title: "Couldn't \(action.verb) “\(alert.title)”",
             body: refusal, sound: false, category: Self.fleetCategory, route: .finding(id, alert))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

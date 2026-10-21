import AppKit
import Foundation
import UserNotifications
import VHKeyBackup

/// The "N vault keys need backup" notification (UserNotifications), with an action that opens Recovery Keys.
/// Permission is asked only when the user turns notifications on (Settings → 1Password).
@MainActor
final class RecoveryKeysNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "sh.vaulthalla.recovery-keys"
    nonisolated static let openAction = "open-recovery-keys"

    /// Called when the user clicks the notification or its action.
    var onOpen: (() -> Void)?
    private var registered = false

    /// The notification center, unless the app runs without a bundle (`swift test`, previews), where it traps.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private func register() {
        guard !registered, let center else { return }
        registered = true
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open Recovery Keys", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [open], intentIdentifiers: []),
        ])
        center.delegate = self
    }

    func requestPermission() async -> Bool {
        register()
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func post(_ rows: [VaultKeyRow]) async {
        register()
        guard let center, !rows.isEmpty else { return }
        let unavailable = rows.filter(\.isKeyUnavailable)
        let content = UNMutableNotificationContent()
        if unavailable.isEmpty {
            content.title = rows.count == 1 ? "1 vault key needs backup" : "\(rows.count) vault keys need backup"
        } else {
            content.title = unavailable.count == 1 ? "A vault can't use its key" : "\(unavailable.count) vaults can't use their keys"
        }
        let names = rows.prefix(3).map { "\($0.vaultName) on \($0.nodeName)" }
        content.body = names.joined(separator: ", ") + (rows.count > 3 ? ", and \(rows.count - 3) more." : ".")
        content.categoryIdentifier = Self.category
        content.sound = .default
        let request = UNNotificationRequest(identifier: "recovery-keys", content: content, trigger: nil)
        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier == Self.category else { return }
        await MainActor.run {
            NSApp.activate()
            onOpen?()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

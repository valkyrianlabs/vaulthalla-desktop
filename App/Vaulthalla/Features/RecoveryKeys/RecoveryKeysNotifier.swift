import Foundation
import VHKeyBackup

/// The "N vault keys need backup" notification, with an action that opens Recovery Keys. Posted through the
/// ``NotificationHub``, which owns the notification centre and routes the click. Permission is asked only when the
/// user turns these notifications on (Settings ▸ 1Password).
final class RecoveryKeysNotifier {
    static let identifier = "recovery-keys"

    func requestPermission() async -> Bool {
        await NotificationHub.shared.requestPermission()
    }

    func post(_ rows: [VaultKeyRow]) async {
        guard !rows.isEmpty else { return }
        let unavailable = rows.filter(\.isKeyUnavailable)
        let title: String
        if unavailable.isEmpty {
            title = rows.count == 1 ? "1 vault key needs backup" : "\(rows.count) vault keys need backup"
        } else {
            title = unavailable.count == 1 ? "A vault can't use its key" : "\(unavailable.count) vaults can't use their keys"
        }
        let names = rows.prefix(3).map { "\($0.vaultName) on \($0.nodeName)" }
        let body = names.joined(separator: ", ") + (rows.count > 3 ? ", and \(rows.count - 3) more." : ".")
        NotificationHub.shared.post(id: Self.identifier, title: title, body: body, sound: true,
                                    category: NotificationHub.recoveryKeysCategory, route: .recoveryKeys)
    }
}

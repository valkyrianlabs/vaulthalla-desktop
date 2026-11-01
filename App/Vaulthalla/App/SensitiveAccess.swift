import AppKit
import Foundation
import LocalAuthentication
import Observation
import SwiftUI

/// The optional Touch ID gate for sensitive views (desktop#7): Recovery Keys, Credentials and Access. Off by default:
/// this macOS account is already the authenticated space, and the node's RBAC decides what the paired user may do. On,
/// those views ask for Touch ID (or this Mac's password, where there is no Touch ID) before they show, and lock again
/// when the screen locks, the Mac sleeps or another user takes over the screen.
///
/// It gates views only. Sessions, key backups to 1Password, the File Provider extension and the background agent never
/// ask and never wait for it.
@Observable
final class SensitiveAccess {
    static let requiredKey = "security.unlockForSensitiveViews"

    private(set) var isRequired: Bool
    private(set) var isUnlocked = false
    /// Why the last unlock failed, other than the person cancelling.
    private(set) var problem: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isRequired = defaults.bool(forKey: Self.requiredKey)
        let lock: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.lock() } }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (DistributedNotificationCenter.default(),
             DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                                                 queue: .main, using: lock)),
            (workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main,
                                              using: lock)),
            (workspace, workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                                              queue: .main, using: lock)),
        ]
    }

    isolated deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    /// Whether the sensitive views show now.
    var isOpen: Bool { !isRequired || isUnlocked }

    /// Asks for Touch ID or the Mac's password. True once unlocked.
    @discardableResult
    func unlock(reason: String = "show recovery keys, credentials and access settings") async -> Bool {
        if isOpen { return true }
        guard await authenticate(reason: reason) else { return false }
        isUnlocked = true
        return true
    }

    func lock() {
        isUnlocked = false
    }

    /// Turning the gate on locks the views now; turning it off asks first, so nobody at an unlocked Mac can drop it
    /// without the owner's finger or password.
    func setRequired(_ required: Bool) async {
        guard required != isRequired else { return }
        if !required, !isUnlocked, !(await authenticate(reason: "stop asking before showing sensitive views")) { return }
        isRequired = required
        isUnlocked = false
        defaults.set(required, forKey: Self.requiredKey)
    }

    private func authenticate(reason: String) async -> Bool {
        problem = nil
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return false
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}

/// Shows `content` only while ``SensitiveAccess`` is open, else a locked placeholder with an Unlock button.
struct SensitiveGate<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    @Environment(AppModel.self) private var model

    var body: some View {
        let access = model.sensitiveAccess
        if access.isOpen {
            content
        } else {
            EmptyState("\(title) is locked", systemImage: "lock",
                       message: access.problem ?? "Unlock with Touch ID or your Mac's password to show it. Vaulthalla asks because Settings ▸ General ▸ Security says so.") {
                Button("Unlock", systemImage: "touchid") { Task { await access.unlock() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

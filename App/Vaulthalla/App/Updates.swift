import AppKit
import Combine
import Observation
import Sparkle
import SwiftUI

/// Sparkle updates (docs/architecture.md D8). The feed is the `appcast.xml` of the latest release in the public
/// valkyrianlabs/vaulthalla-desktop-releases repository (`SUFeedURL` in Info.plist); every update is verified against
/// the EdDSA public key `SUPublicEDKey` and must carry the app's Developer ID signature. Debug builds never start the
/// updater, so a development build can't replace itself.
@MainActor
final class Updates {
    static let shared = Updates()

    let controller: SPUStandardUpdaterController
    private let reminders = UpdateReminders()

    var updater: SPUUpdater { controller.updater }

    /// The version of an update that arrived while no window was open, until the person has seen it.
    var pending: String? { reminders.pending }

    private init() {
        #if DEBUG
        let start = false
        // `-VHDebugPendingUpdate 0.7.1`: show the "update ready" state without an updater.
        reminders.pending = UserDefaults.standard.string(forKey: "VHDebugPendingUpdate")
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil,
                                                  userDriverDelegate: reminders)
    }

    /// Brings the waiting update's dialog forward (the panel's row, the notification's click).
    func showPending() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        updater.checkForUpdates()
    }
}

/// Sparkle's gentle reminders (docs/mac-experience.md §3): with no window open, a scheduled update must not open a
/// dialog from nowhere. It shows as "update ready" in the menu bar panel and as one notification instead; clicking
/// either opens Sparkle's normal dialog.
@Observable
final class UpdateReminders: NSObject, SPUStandardUserDriverDelegate {
    static let notificationID = "update"

    var pending: String?

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows the update itself only when the app is in front of the person (a regular app with a window).
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated { immediateFocus && MainWindow.isVisible }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // Sparkle shows it (the person asked, or the app is in front): nothing to remind about.
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            pending = version
            NotificationHub.shared.post(id: Self.notificationID, title: "Vaulthalla \(version) is ready",
                                        body: "Open Vaulthalla to install it.", sound: false,
                                        category: NotificationHub.updateCategory, route: .update)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            pending = nil
            NotificationHub.shared.withdraw(id: Self.notificationID)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            pending = nil
            MainWindow.updatePresence()
        }
    }
}

/// Mirrors the updater's KVO properties for SwiftUI.
@MainActor
final class UpdaterState: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    private let updater: SPUUpdater

    init(updater: SPUUpdater = Updates.shared.updater) {
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

/// "Check for Updates…" under the app menu's About item.
struct CheckForUpdatesButton: View {
    @StateObject private var state = UpdaterState()

    var body: some View {
        Button("Check for Updates…") { state.checkForUpdates() }
            .disabled(!state.canCheckForUpdates)
    }
}

/// The Updates section of Settings → General.
struct UpdateSettingsSection: View {
    @StateObject private var state = UpdaterState()

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $state.automaticallyChecksForUpdates)
            LabeledContent("Check now") {
                Button("Check for Updates…") { state.checkForUpdates() }
                    .disabled(!state.canCheckForUpdates)
            }
        }
    }
}

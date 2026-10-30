import Combine
import Sparkle
import SwiftUI

/// Sparkle updates (docs/architecture.md D8). The feed is the latest GitHub release's `appcast.xml` (`SUFeedURL` in
/// Info.plist); every update is verified against the EdDSA public key `SUPublicEDKey` and must carry the app's
/// Developer ID signature. Debug builds never start the updater, so a development build can't replace itself.
@MainActor
final class Updates {
    static let shared = Updates()

    let controller: SPUStandardUpdaterController

    var updater: SPUUpdater { controller.updater }

    private init() {
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
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

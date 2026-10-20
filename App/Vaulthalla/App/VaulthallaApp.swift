import SwiftUI
import VHCore

@main
struct VaulthallaApp: App {
    @State private var model = AppModel(store: NodeStore(fileURL: NodeStore.defaultFileURL()))

    var body: some Scene {
        // One window: the shell is the app. That also frees ⌘N for Add Node.
        Window("Vaulthalla", id: "main") {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

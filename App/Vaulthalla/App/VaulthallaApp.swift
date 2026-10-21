import Foundation
import SwiftUI
import VHCore
import VHNodes

@main
struct VaulthallaApp: App {
    @State private var model = Self.makeModel()

    private static func makeModel() -> AppModel {
        #if DEBUG
        // `-VHDebugPreviewData YES`: the preview nodes, answering from PREVIEW DATA, without sessions (DebugSnapshot).
        if UserDefaults.standard.bool(forKey: "VHDebugPreviewData") { return PreviewSamples.liveModel() }
        #endif
        return AppModel(store: NodeStore(fileURL: registryURL), keys: DeviceKeys.standard())
    }

    private static var registryURL: URL {
        #if DEBUG
        // `-VHDebugRegistry <path>`: run against another node list (DebugSnapshot, scripted checks).
        if let path = UserDefaults.standard.string(forKey: "VHDebugRegistry") { return URL(filePath: path) }
        #endif
        return NodeStore.defaultFileURL()
    }

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

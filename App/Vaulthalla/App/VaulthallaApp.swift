import Foundation
import os
import SwiftUI
import VHCore
import VHNodes

@main
enum Launch {
    static func main() {
        #if DEBUG
        // `Vaulthalla --developer <command>`: the developer commands (DeveloperCommands.swift), headless.
        if CommandLine.arguments.dropFirst().first == DeveloperCommands.flag {
            DeveloperCommands.run(Array(CommandLine.arguments.dropFirst(2)))
        }
        #endif
        VaulthallaApp.main()
    }
}

struct VaulthallaApp: App {
    @State private var model = Self.makeModel()

    private static func makeModel() -> AppModel {
        #if DEBUG
        // `-VHDebugPreviewData YES`: the preview nodes, answering from PREVIEW DATA, without sessions (DebugSnapshot).
        if UserDefaults.standard.bool(forKey: "VHDebugPreviewData") { return PreviewSamples.liveModel() }
        #endif
        #if DEBUG
        // `-VHDebugRegistry <path>`: run against another node list (DebugSnapshot, scripted checks), never migrated.
        if let path = UserDefaults.standard.string(forKey: "VHDebugRegistry") {
            let lease = CredentialLease(forRegistry: URL(filePath: path), holder: "app")
            try? lease.acquire()
            return AppModel(store: NodeStore(fileURL: URL(filePath: path), lease: lease),
                            keys: DeviceKeys.standard(lease: lease))
        }
        #endif
        // Until the background agent ships, the app is the credential owner (docs/architecture.md §3): it takes the
        // lease next to the registry, moving the registry into the App Group container first when this build has
        // the group. If another process holds the lease, the app runs as a read-only consumer and takes the lease
        // over once that process exits.
        let registry = RegistryOwnership.open(in: .current(), holder: "app")
        Logger(subsystem: "sh.vaulthalla.app", category: "registry").notice(
            "registry \(registry.location.description, privacy: .private): \(registry.migration.description, privacy: .public)")
        return AppModel(store: NodeStore(fileURL: registry.location.registryURL, lease: registry.lease),
                        keys: DeviceKeys.standard(lease: registry.lease), registry: registry)
    }

    var body: some Scene {
        // One window: the shell is the app. That also frees ⌘N for Add Node.
        Window("Vaulthalla", id: "main") {
            RootView()
                .environment(model)
                // `vaulthalla://pair?…` from the web console's Pair a Device dialog (untrusted: parsed defensively).
                .onOpenURL { model.openPairLink($0) }
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

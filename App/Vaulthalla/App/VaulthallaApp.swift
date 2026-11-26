import Foundation
import os
import SwiftUI
import VHCore
import VHNodes

@main
enum Launch {
    static func main() {
        // `Vaulthalla --agent`: the background agent, started by launchd (BackgroundAgent.swift), headless.
        if CommandLine.arguments.dropFirst().first == BackgroundAgent.flag {
            BackgroundAgent.run()
        }
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
    @State private var model = Self.makeAndRegisterModel()
    /// Quit, reopen and the Dock icon (AppDelegate.swift); signs out on quit while "Keep me signed in" is off.
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    /// The menu bar item (docs/mac-experience.md §2), on by default.
    @AppStorage(MenuBarPreferences.showsItemKey) private var showsMenuBarItem = true

    private static func makeAndRegisterModel() -> AppModel {
        let model = makeModel()
        AppDelegate.model = model
        #if DEBUG
        MenuBarDebug.run(model: model)
        #endif
        return model
    }

    private static func makeModel() -> AppModel {
        #if DEBUG
        // `-VHDebugPreviewData YES`: the preview nodes, answering from PREVIEW DATA, without sessions (DebugSnapshot).
        if UserDefaults.standard.bool(forKey: "VHDebugPreviewData") {
            let model = PreviewSamples.liveModel()
            // The menu bar item over PREVIEW DATA; with `-VHDebugNotify YES` what it finds is really notified.
            if UserDefaults.standard.bool(forKey: "VHDebugNotify") {
                NotificationHub.shared.activate()
                NotificationHub.shared.onOpen = { [weak model] route in model?.follow(route) }
                model.fleet.post = { NotificationHub.shared.post($0) }
            }
            model.fleet.start()
            return model
        }
        #endif
        #if DEBUG
        // `-VHDebugRegistry <path>`: run against another node list (DebugSnapshot, scripted checks), never migrated.
        if let path = UserDefaults.standard.string(forKey: "VHDebugRegistry") {
            let lease = CredentialLease(forRegistry: URL(filePath: path), holder: "app")
            try? lease.acquire()
            let model = AppModel(store: NodeStore(fileURL: URL(filePath: path), lease: lease),
                                 keys: DeviceKeys.standard(lease: lease))
            // With `-VHDebugLocalVH <path>` too: set up "this Mac's server" through that stand-in (LocalNodeSetup).
            if UserDefaults.standard.string(forKey: "VHDebugLocalVH") != nil { model.setUpLocalNode() }
            return model
        }
        #endif
        // Until the background agent ships, the app is the credential owner (docs/architecture.md §3): it takes the
        // lease next to the registry, moving the registry into the App Group container first when this build has
        // the group. If another process holds the lease, the app runs as a read-only consumer and takes the lease
        // over once that process exits.
        let registry = RegistryOwnership.open(in: .current(), holder: "app")
        Logger(subsystem: "sh.vaulthalla.app", category: "registry").notice(
            "registry \(registry.location.description, privacy: .private): \(registry.migration.description, privacy: .public)")
        let model = AppModel(store: NodeStore(fileURL: registry.location.registryURL, lease: registry.lease),
                             keys: DeviceKeys.standard(lease: registry.lease), registry: registry)
        model.signOutIfNotKept()
        model.setUpLocalNode()
        model.applyLaunchDefaults()
        return model
    }

    /// Whether the item is in the menu bar, for `MenuBarExtra`. Not the `@AppStorage` binding itself: SwiftUI writes
    /// the status item's visibility back on every update of the app's scenes, and a write that changes nothing would
    /// still start another update (the app then spins at 100% CPU and the item never appears). Dragging the item out
    /// of the menu bar still turns the setting off.
    private var menuBarItemInserted: Binding<Bool> {
        Binding(get: { showsMenuBarItem }, set: { if $0 != showsMenuBarItem { showsMenuBarItem = $0 } })
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

        // Vaulthalla in the menu bar: the fleet's state as the icon, and the panel under it.
        MenuBarExtra(isInserted: menuBarItemInserted) {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

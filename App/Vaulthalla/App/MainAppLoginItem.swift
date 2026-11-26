import AppKit
import Foundation
import ServiceManagement
import VHNodes

/// macOS's own login item for the app (docs/mac-experience.md §4): `SMAppService.mainApp`, which lists Vaulthalla
/// under System Settings ▸ General ▸ Login Items ▸ Open at Login, where the person can remove it like any other app.
struct MainAppLoginItem: LoginItemService {
    var status: LoginItemStatus {
        // Without a bundle (previews) there is nothing to register.
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        return switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// System Settings ▸ General ▸ Login Items.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether this build applies "on by default". Development builds share the app's identifier and preferences
    /// with an installed release, so they neither register themselves nor record that the default was applied.
    static var appliesDefault: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }
}

import AppKit
import SwiftUI

/// Whether the menu bar item is shown (docs/mac-experience.md §2 and §3). While it is, the app keeps running with its
/// window closed; while it isn't, closing the window quits, as before the item existed.
enum MenuBarPreferences {
    static let showsItemKey = "menuBar.show"

    static var showsItem: Bool {
        UserDefaults.standard.object(forKey: showsItemKey) as? Bool ?? true
    }
}

/// The app's one window, reached from code that isn't a view (a notification's click, the menu bar panel, a reopen),
/// and the app's presence: a regular app with a Dock icon while a window is open, menu bar only while none is.
enum MainWindow {
    static let id = "main"

    /// SwiftUI's action for opening the window, kept by the menu bar item's label, which lives as long as the item.
    static var open: OpenWindowAction?

    /// A window of the app's own that counts as "the app is open": the main window or Settings, not the item's panel.
    static func isRegular(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.canBecomeMain && !(window is NSPanel)
    }

    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true && isRegular($0) }
    }

    /// Whether the main window is on screen (not closed, not minimized).
    static var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    /// Brings the main window forward, opening it when it was closed, and makes the app a regular one again.
    static func show() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if let window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let open {
            open(id: id)
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// Matches the Dock icon to what is open: none while only the menu bar item is. Called when windows come and go.
    static func updatePresence() {
        let hasWindow = NSApp.windows.contains { isRegular($0) && ($0.isVisible || $0.isMiniaturized) }
        let wanted: NSApplication.ActivationPolicy = hasWindow || !MenuBarPreferences.showsItem ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate() }
    }

    /// Closes the item's panel (it has no API of its own for that): the key window when it is a panel.
    static func dismissPanel() {
        if let panel = NSApp.keyWindow, !isRegular(panel) { panel.close() }
    }
}

extension Launch {
    /// `Vaulthalla --background`: start with only the menu bar item, as a login launch does.
    static let backgroundFlag = "--background"

    /// Whether this launch should open no window: macOS started the app as a login item (it marks the launch event),
    /// or the flag was passed. Read while the launch event is current (`applicationDidFinishLaunching`).
    static var startedInBackground: Bool {
        if CommandLine.arguments.dropFirst().contains(backgroundFlag) { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

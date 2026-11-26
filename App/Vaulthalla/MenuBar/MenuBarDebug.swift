#if DEBUG
import AppKit
import ApplicationServices
import SwiftUI
import VHNodes

/// DEBUG-only hooks for checking the menu bar item without Screen Recording permission or a person at the mouse
/// (see `DebugSnapshot` for the window's):
///
///     Vaulthalla -VHDebugPreviewData YES -VHDebugPanelSnapshot /tmp/panel.png
///     Vaulthalla -VHDebugPreviewData YES -VHDebugSettingsSnapshot /tmp/settings
///     Vaulthalla -VHDebugMenuBarIcons /tmp/icons
///     Vaulthalla -VHDebugPreviewData YES [--background] -VHDebugPresence /tmp/presence.txt [-VHDebugCloseWindow YES]
///
/// - `-VHDebugPanelSnapshot` renders the panel to a PNG once the nodes have answered, then the app exits.
/// - `-VHDebugSettingsSnapshot` renders Settings ▸ General and ▸ Notifications into the directory, then exits.
/// - `-VHDebugMenuBarIcons` writes every state of the item's image, as macOS tints it on a light and on a dark menu
///   bar, into the directory, then the app exits.
/// - `-VHDebugPresence` writes what the running app is, a few seconds after launch: whether the launch counted as
///   a background one, the activation policy (regular, or accessory: no Dock icon), how many regular windows are
///   open, and where the menu bar item is on screen. With `-VHDebugCloseWindow YES` the main window is closed
///   first, as a person would close it. The app keeps running.
///
/// The panel can't be opened from code on current macOS (the item's button has no action, and the system delivers
/// its clicks): seeing it open under the item takes a real click.
enum MenuBarDebug {
    static func run(model: AppModel) {
        let defaults = UserDefaults.standard
        if let directory = defaults.string(forKey: "VHDebugMenuBarIcons") {
            writeIcons(to: URL(filePath: directory))
            exit(0)
        }
        if let path = defaults.string(forKey: "VHDebugPanelSnapshot") {
            Task {
                await settle(model)
                let ok = snapshot(MenuBarPanel().environment(model), to: URL(filePath: path))
                exit(ok ? 0 : 1)
            }
        }
        if let directory = defaults.string(forKey: "VHDebugSettingsSnapshot") {
            Task {
                await settle(model)
                let url = URL(filePath: directory)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let general = snapshot(GeneralSettingsView().environment(model).frame(width: 520)
                    .preferredColorScheme(.dark), to: url.appending(path: "settings-general.png"))
                let notifications = snapshot(NotificationsSettingsView().environment(model).frame(width: 520)
                    .preferredColorScheme(.dark), to: url.appending(path: "settings-notifications.png"))
                exit(general && notifications ? 0 : 1)
            }
        }
        if let path = defaults.string(forKey: "VHDebugPresence") {
            let closes = defaults.bool(forKey: "VHDebugCloseWindow")
            Task {
                try? await Task.sleep(for: .seconds(3))
                await NotificationHub.shared.refreshPermission()
                if closes {
                    MainWindow.window?.performClose(nil)
                    try? await Task.sleep(for: .seconds(1))
                }
                // `-VHDebugLoginItem on|off`: flip "Open at login" as the Settings switch does.
                if let login = defaults.string(forKey: "VHDebugLoginItem") {
                    model.loginItem.setEnabled(login == "on")
                }
                let regular = NSApp.windows.filter { MainWindow.isRegular($0) && ($0.isVisible || $0.isMiniaturized) }
                let frame = statusItemFrame()
                let lines = [
                    "background-launch: \(AppDelegate.launchedInBackground)",
                    "policy: \(NSApp.activationPolicy() == .regular ? "regular" : "accessory")",
                    "regular-windows: \(regular.count)",
                    "status-item: \(frame.map { "\(Int($0.minX)) \(Int($0.minY)) \(Int($0.width)) \(Int($0.height))" } ?? "none")",
                    "fleet: \(model.fleet.status.level) \(model.fleet.status.headline)",
                    "login-item: \(model.loginItem.status)\(model.loginItem.problem.map { " (\($0))" } ?? "")",
                    "notifications: \(NotificationHub.shared.permission)",
                ]
                try? lines.joined(separator: "\n").appending("\n").write(to: URL(filePath: path), atomically: true,
                                                                         encoding: .utf8)
            }
        }
    }

    /// Waits (bounded) for the monitor's first check, then for the views to settle.
    private static func settle(_ model: AppModel) async {
        for _ in 0..<100 where model.fleet.checkedAt == nil || model.fleet.isChecking {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// The app's menu bar item's frame on screen (top-left origin), from this process's own accessibility tree.
    static func statusItemFrame() -> CGRect? {
        let app = AXUIElementCreateApplication(getpid())
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let bar = extras, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let item = (children as? [AXUIElement])?.first else { return nil }
        var frame = CGRect.zero
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        AXValueGetValue(position as! AXValue, .cgPoint, &frame.origin)
        AXValueGetValue(size as! AXValue, .cgSize, &frame.size)
        return frame
    }

    private static func snapshot(_ view: some View, to url: URL) -> Bool {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Each level drawn the way the menu bar draws a template image: its alpha, filled with the bar's ink.
    private static func writeIcons(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let levels: [(FleetStatus.Level, String)] = [(.quiet, "quiet"), (.warnings, "warnings"),
                                                     (.attention, "attention"), (.notReporting, "not-reporting")]
        let bars: [(name: String, bar: NSColor, ink: NSColor)] = [
            ("light", NSColor(white: 0.93, alpha: 1), .black), ("dark", NSColor(white: 0.14, alpha: 1), .white),
        ]
        let scale: CGFloat = 8
        let cell = NSSize(width: 36 * scale, height: 24 * scale)
        for bar in bars {
            let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(levels.count), height: cell.height))
            sheet.lockFocus()
            bar.bar.setFill()
            NSRect(origin: .zero, size: sheet.size).fill()
            for (index, level) in levels.enumerated() {
                let glyph = MenuBarIcon.image(for: level.0)
                let side = MenuBarIcon.size.width * scale
                let tinted = NSImage(size: NSSize(width: side, height: side))
                tinted.lockFocus()
                glyph.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
                bar.ink.setFill()
                NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceIn)
                tinted.unlockFocus()
                tinted.draw(at: NSPoint(x: cell.width * CGFloat(index) + (cell.width - side) / 2,
                                        y: (cell.height - side) / 2),
                            from: .zero, operation: .sourceOver, fraction: 1)
            }
            sheet.unlockFocus()
            guard let tiff = sheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: directory.appending(path: "menu-bar-icons-\(bar.name).png"))
        }
    }
}
#endif

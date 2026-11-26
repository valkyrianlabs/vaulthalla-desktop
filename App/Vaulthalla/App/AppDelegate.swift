import AppKit

/// The app's lifecycle (docs/mac-experience.md §3 and §4):
/// - while the menu bar item is shown, closing the window doesn't quit, and the Dock icon follows whether a window is
///   open;
/// - a launch at login (or with `--background`) opens no window;
/// - quitting, and logging out of macOS, signs out while "Keep me signed in on this Mac" is off (SignIn.swift).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model. Set at launch, not by a window: a background launch has none.
    static weak var model: AppModel?
    private var model: AppModel? { Self.model }
    /// Whether this launch opened no window (a login launch, or `--background`).
    private(set) static var launchedInBackground = false
    private var signingOut = false
    private var observers: [any NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read now, while the launch event is the current Apple event.
        let background = Launch.startedInBackground && MenuBarPreferences.showsItem
        Self.launchedInBackground = background
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the window has actually gone (or come): `willClose` arrives while it is still visible.
                DispatchQueue.main.async { MainActor.assumeIsolated { MainWindow.updatePresence() } }
            })
        }
        if background {
            for window in NSApp.windows where MainWindow.isRegular(window) { window.close() }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Today's behaviour while the menu bar item is hidden; with it, the app stays to watch the nodes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarPreferences.showsItem
    }

    /// Opened again while running (Spotlight, Finder, the Dock) with no window: bring the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, MainWindow.open != nil else { return true }
        MainWindow.show()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !SignInPreferences.keepSignedIn, let model, model.isCredentialOwner, model.hasSignedInNodes else {
            return .terminateNow
        }
        if !signingOut {
            signingOut = true
            Task {
                await model.signOut()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

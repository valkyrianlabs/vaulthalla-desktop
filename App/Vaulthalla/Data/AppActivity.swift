import AppKit

/// Tells the model whether polling may run: the app is active, not hidden, and one of its windows is visible
/// (not minimized or fully covered). Server data still loads when a view appears; only polling pauses.
@MainActor
final class AppActivity {
    private var observers: [any NSObjectProtocol] = []
    private let onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        update()
    }

    private func update() {
        let app = NSApplication.shared
        let visible = app.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
        onChange(app.isActive && !app.isHidden && visible)
    }
}

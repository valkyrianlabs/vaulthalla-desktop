public import Foundation
public import Observation

/// Whether macOS opens Vaulthalla at login, as the system reports it (docs/mac-experience.md §4).
public enum LoginItemStatus: Sendable, Hashable {
    /// Listed under System Settings ▸ General ▸ Login Items ▸ Open at Login.
    case enabled
    case disabled
    /// Registered, but the person turned it off in System Settings, or macOS wants their approval.
    case requiresApproval
    /// This build can't be a login item (not a bundle, or the system doesn't know it).
    case unavailable
}

/// The system's login item service (`SMAppService.mainApp` in the app; a fake in tests).
public protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// "Open at login", on by default: the first launch of a build that applies defaults registers once and remembers it
/// did. It is never registered again on its own, so removing it (here or in System Settings) sticks. The switch shows
/// the system's state, never a saved copy of it.
@MainActor
@Observable
public final class LoginItemController {
    public static let defaultAppliedKey = "login.defaultApplied"

    public private(set) var status: LoginItemStatus
    /// Why the last change didn't take, in the system's words.
    public private(set) var problem: String?

    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appliesDefault: Bool

    /// `appliesDefault`: false for development builds, which share preferences with an installed release and must
    /// neither register themselves by default nor record that the default was applied.
    public init(service: any LoginItemService, defaults: UserDefaults = .standard, appliesDefault: Bool) {
        self.service = service
        self.defaults = defaults
        self.appliesDefault = appliesDefault
        status = service.status
    }

    public var isEnabled: Bool { status == .enabled }

    /// Called once per launch, and only while the app has a presence to open into (the menu bar item is shown).
    public func applyDefaultIfNeeded() {
        guard appliesDefault, !defaults.bool(forKey: Self.defaultAppliedKey) else { return }
        // Recorded first: a failed registration is not retried behind the person's back either.
        defaults.set(true, forKey: Self.defaultAppliedKey)
        if service.status == .disabled { set(true) }
        refresh()
    }

    public func setEnabled(_ enabled: Bool) {
        // Flipping the switch is a choice: the default is never applied over it afterwards.
        if appliesDefault { defaults.set(true, forKey: Self.defaultAppliedKey) }
        set(enabled)
    }

    /// Re-reads the system's state (Settings appeared, the app became active).
    public func refresh() {
        let current = service.status
        if current != status { status = current }
    }

    private func set(_ enabled: Bool) {
        do {
            if enabled { try service.register() } else { try service.unregister() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        status = service.status
    }
}

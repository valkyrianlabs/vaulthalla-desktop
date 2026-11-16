public import Foundation
import CoreFoundation
public import VHCore
import OSLog

/// How the File Provider extension tells the app that the provider refused a Desktop-only vault's bucket key (401/403)
/// without a cloud call of its own: a marker file per vault in the App Group container they already share
/// (`FileProvider/desktop-<uid>.refused`, the refused key's id and when), and a Darwin notification
/// (`<App Group>.vault-key-refused`, no payload) that wakes an app that is running. The file is the record: an app that
/// wasn't running, or missed the notification, finds it at launch and on every check. Needs no entitlement beyond the
/// App Group (a sandboxed process may post Darwin notifications under its group's prefix).
public struct KeyRefusalSignal: Sendable {
    public struct Refusal: Codable, Sendable, Equatable {
        public var vaultUid: String
        public var keyID: String
        public var at: Date
    }

    public let directory: URL
    public let notificationName: String
    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "vault.keys")

    /// `container`: the App Group container (Application Support in a build without the group).
    public init(container: URL, group: String? = AppGroup.entitledIdentifier()) {
        directory = container.appending(path: "FileProvider", directoryHint: .isDirectory)
        notificationName = (group ?? "sh.vaulthalla.app") + ".vault-key-refused"
    }

    func url(_ uid: String) -> URL { directory.appending(path: "desktop-\(uid).refused", directoryHint: .notDirectory) }

    /// The extension: the provider refused `keyID` for `uid`.
    public func post(uid: String, keyID: String, at: Date = Date()) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let e = JSONEncoder()
            e.dateEncodingStrategy = .secondsSince1970
            try e.encode(Refusal(vaultUid: uid, keyID: keyID, at: at)).write(to: url(uid), options: [.atomic])
        } catch {
            Self.log.error("refusal marker not written: \(error.localizedDescription, privacy: .public)")
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(notificationName as CFString), nil, nil, true)
    }

    /// The app: every refusal waiting, each taken (its marker removed) as it is returned.
    public func take() -> [Refusal] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        var out: [Refusal] = []
        for name in names where name.hasPrefix("desktop-") && name.hasSuffix(".refused") {
            let u = directory.appending(path: name, directoryHint: .notDirectory)
            if let data = try? Data(contentsOf: u), let r = try? d.decode(Refusal.self, from: data) { out.append(r) }
            try? FileManager.default.removeItem(at: u)
        }
        return out
    }

    /// The app: calls `handler` whenever the extension posts, until the returned observer is released.
    public func observe(_ handler: @escaping @Sendable () -> Void) -> Observer { Observer(name: notificationName, handler) }

    /// A Darwin notification observer; removed when released.
    public final class Observer: @unchecked Sendable {
        let handler: @Sendable () -> Void

        init(name: String, _ handler: @escaping @Sendable () -> Void) {
            self.handler = handler
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                            { _, observer, _, _, _ in
                                                guard let observer else { return }
                                                Unmanaged<Observer>.fromOpaque(observer).takeUnretainedValue().handler()
                                            }, name as CFString, nil, .deliverImmediately)
        }

        deinit {
            CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        }
    }
}

/// What the extension knows about a vault's bucket key from the shared group alone (it never asks the cloud), in words.
public enum SharedKeyState: Sendable, Equatable {
    case inForce(expiresAt: Date)
    /// The app never stored one (or hasn't since the vault was placed here).
    case none
    /// Past its expiry: the app wasn't running to renew it.
    case expired(at: Date)
    /// The provider refused it; the app was told.
    case refused

    public var sentence: String? {
        switch self {
        case .inForce: nil
        case .none:
            "Paused: this Mac has no storage key for this vault yet. Open Vaulthalla to get one. Your files and changes on this Mac are kept."
        case .expired:
            "Paused: this vault's storage key expired while Vaulthalla wasn't running. Open Vaulthalla to renew it. Your files and changes on this Mac are kept and are sent once it is renewed."
        case .refused:
            "Paused: the storage provider refused this vault's key. Vaulthalla is asked for a new one; open Vaulthalla if it isn't running. Your files and changes on this Mac are kept."
        }
    }
}

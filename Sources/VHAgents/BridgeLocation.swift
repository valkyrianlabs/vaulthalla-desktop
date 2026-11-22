public import Foundation

/// Whether the bridge's path will still be there when an AI app starts it later. A registration stores the path, so
/// adding is blocked while the app runs from somewhere it won't stay: a disk image, an App Translocation copy (an app
/// opened from Downloads without being moved), the Trash or a temporary folder.
public enum BridgeLocation: Equatable, Sendable {
    /// Stable; `inApplications` is false for a copy kept elsewhere (a development build), which works but moves easily.
    case stable(inApplications: Bool)
    case missing
    case unstable(String)

    public static func check(_ bridge: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> BridgeLocation {
        let path = bridge.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: path) else { return .missing }
        if path.contains("/AppTranslocation/") {
            return .unstable("macOS is running Vaulthalla from a temporary copy. Move it to Applications and open it from there.")
        }
        if path.hasPrefix("/Volumes/") {
            if (try? bridge.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
                || (try? bridge.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) != true {
                return .unstable("Vaulthalla is running from a disk image or an external disk. Move it to Applications first.")
            }
        }
        let homePath = home.path(percentEncoded: false)
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path(percentEncoded: false)
        if path.hasPrefix(homePath + "/.Trash/") || path.contains("/.Trashes/") {
            return .unstable("Vaulthalla is in the Trash.")
        }
        if bridge.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(temporary) || path.hasPrefix("/private/tmp/")
            || path.hasPrefix("/tmp/") {
            return .unstable("Vaulthalla is running from a temporary folder. Move it to Applications first.")
        }
        let inApplications = path.hasPrefix("/Applications/") || path.hasPrefix(homePath + "/Applications/")
        return .stable(inApplications: inApplications)
    }

    public var allowsAdding: Bool {
        if case .stable = self { true } else { false }
    }
}

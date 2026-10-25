public import Foundation
import Security

/// The App Group the app, the File Provider extension and every other Desktop process share
/// (docs/architecture.md §3, "Signing and the shared container"): `<TEAM>.sh.vaulthalla.desktop`, the team-prefixed
/// macOS form, which needs no portal registration or profile entry.
///
/// A process may use the group only when its signature carries the `com.apple.security.application-groups`
/// entitlement naming it. That takes a development team, so unsigned, ad-hoc and `swift run` builds have no group and
/// keep the registry in Application Support.
public enum AppGroup {
    /// What follows the team prefix.
    public static let suffix = "sh.vaulthalla.desktop"
    public static let entitlement = "com.apple.security.application-groups"

    /// Whether `identifier` is a team-prefixed Vaulthalla group: a 10-character alphanumeric team id, a dot, then
    /// ``suffix``.
    public static func isVaulthallaGroup(_ identifier: String) -> Bool {
        guard identifier.hasSuffix("." + suffix) else { return false }
        let team = identifier.dropLast(suffix.count + 1)
        return team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The Vaulthalla group named in `groups` (an `application-groups` entitlement value), if any.
    public static func vaulthallaGroup(in groups: [String]) -> String? {
        groups.first(where: isVaulthallaGroup)
    }

    /// The Vaulthalla group this process's signature entitles it to, read from its own entitlements; nil when it has
    /// none (unsigned or ad hoc).
    public static func entitledIdentifier() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil),
              let groups = value as? [String]
        else { return nil }
        return vaulthallaGroup(in: groups)
    }

    /// The group's container, `~/Library/Group Containers/<group>`, when this process is entitled to `identifier`.
    public static func containerURL(for identifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

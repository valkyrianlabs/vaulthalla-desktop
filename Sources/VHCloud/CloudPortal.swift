public import Foundation

/// Where Desktop sends the person: the Vaulthalla Cloud API it signs requests to, and the portal it opens for
/// everything that needs the account holder's session or a step-up (docs/cloud-storage.md, "Where each action goes").
public struct CloudEnvironment: Sendable, Hashable {
    public var api: String
    public var portal: URL

    public static let production = CloudEnvironment(api: "https://api.vaulthalla.cloud",
                                                    portal: URL(string: "https://app.vaulthalla.cloud")!)

    public init(api: String, portal: URL) {
        self.api = api
        self.portal = portal
    }

    /// The release builds' environment is fixed; debug builds may name others (`cloud.endpoint`, `cloud.portal`).
    public static func resolve(debug: Bool, defaults: UserDefaults = .standard) -> CloudEnvironment {
        guard debug else { return .production }
        let api = defaults.string(forKey: "cloud.endpoint") ?? production.api
        let portal = defaults.string(forKey: "cloud.portal").flatMap(URL.init(string:)) ?? production.portal
        return CloudEnvironment(api: api, portal: portal)
    }

    /// The portal page where the account holder enters this Mac's link code.
    public var linkApproval: URL { portal.appending(path: "approvals") }

    /// The portal page for a key request: the id travels in the fragment, out of access logs.
    public func keyRequest(_ id: String) -> URL? { page("approvals/key-request", fragment: id) }
    public var approvals: URL { portal.appending(path: "approvals") }
    public var recoveryKey: URL { portal.appending(path: "recovery-key") }
    public var billing: URL { portal.appending(path: "billing") }
    public var servers: URL { portal.appending(path: "servers") }
    public var vaults: URL { portal.appending(path: "vaults") }

    private func page(_ path: String, fragment: String) -> URL? {
        guard var c = URLComponents(url: portal.appending(path: path), resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = fragment
        return c.url
    }

    /// Whether `url` may be opened: https on the configured portal's origin only (a billing hand-off's URL comes from
    /// the cloud, so it is checked like any other). A local portal over http is allowed only where the portal itself
    /// is local.
    public func mayOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              let portalScheme = portal.scheme?.lowercased(), let portalHost = portal.host?.lowercased(),
              url.user == nil, url.password == nil
        else { return false }
        let localPortal = portalScheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(portalHost)
        guard scheme == "https" || (localPortal && scheme == "http") else { return false }
        return scheme == portalScheme && host == portalHost && (url.port ?? defaultPort(scheme)) == (portal.port ?? defaultPort(portalScheme))
    }

    private func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }
}

/// Opens a portal page in the browser. A protocol so the later store app can put StoreKit behind billing.
public protocol BrowserHandoff: Sendable {
    @MainActor func open(_ url: URL) -> Bool
}

/// The plan's state in Desktop's words (the portal's, `portal.md`).
public enum PlanWording {
    public static func state(_ billing: CloudBilling, formatDate: (Date) -> String) -> String {
        let deletion = billing.deletionAt.map { formatDate(Date(timeIntervalSince1970: TimeInterval($0))) }
        let next = billing.next?.at.map { formatDate(Date(timeIntervalSince1970: TimeInterval($0))) }
        switch billing.state {
        case "active": return "Your plan is active."
        case "past_due":
            return "Your payment didn't go through. Everything keeps working until \(next ?? "the next step")."
        case "restricted": return "Read-only: you can open and delete files, not add new ones."
        case "suspended": return "Paused. Your files are kept, but your servers can't reach them until payment is updated."
        case "ended":
            return "Your plan ended. Files stored in Vaulthalla Cloud are deleted on \(deletion ?? "a later date") unless you move them."
        default: return "No paid plan."
        }
    }

    /// The one billing action the Account pane offers.
    public enum Action: Sendable, Hashable {
        case choosePlan
        case updatePayment
        case manageBilling
    }

    public static func action(_ billing: CloudBilling) -> Action {
        switch billing.state {
        case "past_due", "restricted", "suspended": .updatePayment
        case "active": .manageBilling
        default: .choosePlan
        }
    }
}

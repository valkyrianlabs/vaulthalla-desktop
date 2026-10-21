import AppKit
import Foundation
import VHContract

/// How the S3 gateway screens name things, as the web console does (features/gateway/model.ts). They format what the
/// daemon sent; none of them invents a value.
nonisolated enum GatewayFormat {
    struct Choice: Hashable {
        var value: String
        var label: String
        var hint: String
    }

    static let scopeModes: [Choice] = [
        Choice(value: "user_access", label: "Same as the user",
               hint: "The key acts with its principal's own vault roles and overrides. No extra gateway policy."),
        Choice(value: "vault_allowlist", label: "Selected vaults",
               hint: "Only the vaults you select, with a default vault role (and optional per-vault exceptions)."),
        Choice(value: "global", label: "All bound buckets",
               hint: "Every bucket binding, with a default vault role. Needs an admin principal and manage_credentials."),
    ]

    static func scopeLabel(_ mode: String) -> String {
        scopeModes.first { $0.value == mode }?.label ?? Format.words(mode)
    }

    static let bucketModes: [String: Choice] = [
        "local": Choice(value: "local", label: "Local", hint: "Objects live in the vault on this server."),
        "remote_cache": Choice(value: "remote_cache", label: "Remote cache",
                               hint: "Served from a local cache, synced to the vault's S3 bucket."),
        "remote_proxy": Choice(value: "remote_proxy", label: "Remote proxy",
                               hint: "Requests pass through to the vault's S3 bucket."),
    ]

    static func bucketModeLabel(_ mode: String) -> String {
        bucketModes[mode]?.label ?? Format.words(mode)
    }

    static let budgetModes: [Choice] = [
        Choice(value: "report", label: "Report", hint: "Record estimated spend; never warn or block."),
        Choice(value: "warn", label: "Warn", hint: "Notify when a limit would be exceeded, but let requests run."),
        Choice(value: "enforce", label: "Enforce", hint: "Refuse requests that would exceed a limit."),
    ]

    /// S3 bucket naming (the gateway enforces the full rules; this catches the common mistakes early).
    static func bucketNameProblem(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if name.count < 3 || name.count > 63 { return "Use 3–63 characters." }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        let edges = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        guard name.allSatisfy(allowed.contains), let first = name.first, let last = name.last,
              edges.contains(first), edges.contains(last)
        else { return "Lowercase letters, digits, dots and hyphens; start and end with a letter or digit." }
        return nil
    }

    /// A plain decimal amount ("12.50").
    static func isAmount(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty, parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts.count == 1 || !parts[1].isEmpty
        else { return false }
        return true
    }

    /// The daemon's decimal string in its currency; the daemon's own text when it isn't a number.
    static func money(_ amount: String?, currency: String) -> String? {
        guard let amount, !amount.isEmpty else { return nil }
        guard let value = Decimal(string: amount) else { return amount }
        return value.formatted(.currency(code: currency.isEmpty ? "USD" : currency).precision(.fractionLength(2...4)))
    }

    static func epoch(_ seconds: Int64?) -> Date? {
        seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    static func moment(_ seconds: Int64?) -> String? {
        epoch(seconds)?.formatted(date: .abbreviated, time: .shortened)
    }

    static func number(_ value: Int64) -> String {
        value.formatted(.number)
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension WsModel.S3GatewayCredential {
    /// Revoked keys can't come back; an expired one stays listed until revoked.
    nonisolated var isExpired: Bool {
        guard let expiresAt else { return false }
        return TimeInterval(expiresAt) < Date.now.timeIntervalSince1970
    }

    nonisolated var stateLabel: String {
        if !enabled { return "Revoked" }
        if isExpired { return "Expired" }
        return "Active"
    }

    nonisolated var stateTone: StatusTone {
        if !enabled || isExpired { return .unknown }
        return .info
    }

    nonisolated var principalName: String {
        principalUser?.name ?? "User #\(principalUserID)"
    }
}

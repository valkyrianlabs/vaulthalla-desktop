public import Foundation

/// A managed vault's line and the storage pane's sentences in plain words (docs/cloud-storage.md, "The Vaulthalla
/// Cloud section"), from what a server's `cloud.storage.status` reports. Pure, so every state and reason is a table
/// test. Nothing here says the service is open.
public enum ManagedStorageWording {
    public enum Tone: Sendable, Hashable { case ok, info, warn, danger, neutral }

    public struct Line: Sendable, Hashable {
        public var text: String
        public var tone: Tone
    }

    /// What one `CloudStorageVault` reports, as plain values.
    public struct Vault: Sendable, Hashable {
        public var storage: String
        public var switchOn: Bool?
        public var state: String
        public var reason: String?
        public var access: String?
        public var bytesDone: Int64?
        public var bytesTotal: Int64?
        public var etaSeconds: Int64?
        public var lostFiles: Int
        public var lastError: String?

        public init(storage: String, switchOn: Bool?, state: String, reason: String? = nil, access: String? = nil,
                    bytesDone: Int64? = nil, bytesTotal: Int64? = nil, etaSeconds: Int64? = nil, lostFiles: Int = 0,
                    lastError: String? = nil) {
            self.storage = storage
            self.switchOn = switchOn
            self.state = state
            self.reason = reason
            self.access = access
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.etaSeconds = etaSeconds
            self.lostFiles = lostFiles
            self.lastError = lastError
        }
    }

    public static func line(_ v: Vault, server: String) -> Line {
        switch v.storage {
        case "own": return Line(text: "Uses its own storage", tone: .neutral)
        case "local": return Line(text: "Only on \(server)", tone: .neutral)
        default: break
        }
        if v.reason == "ended_pending_confirmation" {
            return Line(text: "Your plan ended: no access until it becomes local on \(server)", tone: .danger)
        }
        switch v.state {
        case "unregistered" where v.reason == "empty", "registered" where v.reason == "empty":
            return Line(text: "Empty: stored after its first file", tone: .neutral)
        case "unregistered", "registered", "waiting":
            return Line(text: "Not stored yet: " + waiting(v.reason, server: server), tone: v.reason == "payment_required"
                            || v.reason == "over_quota" ? .warn : .info)
        case "keyed": return Line(text: "Its storage is ready; uploading starts shortly", tone: .info)
        case "attaching": return Line(text: "Uploading" + progress(v), tone: .info)
        case "active":
            switch v.access {
            case "read_only": return Line(text: "Read-only: you can open and delete files, not add new ones", tone: .warn)
            case "none": return Line(text: "No access: \(server) can't reach its storage until payment is updated", tone: .danger)
            default:
                if v.reason == "rotation_requested" { return Line(text: "Stored in Vaulthalla Cloud; getting a new storage key", tone: .ok) }
                return Line(text: "Stored in Vaulthalla Cloud", tone: .ok)
            }
        case "detaching":
            if v.reason == "waiting_for_access" {
                return Line(text: "Making it local again: waiting until \(server) can reach its storage", tone: .warn)
            }
            return Line(text: "Making it local again" + progress(v), tone: .info)
        case "off": return Line(text: "Off: only on \(server)", tone: .neutral)
        case "moved":
            if v.reason == "unlinked" { return Line(text: "\(server) was unlinked: kept on \(server) without its storage", tone: .warn) }
            return Line(text: "Moved to another server; \(server) keeps its local copy", tone: .neutral)
        case "ejected": return Line(text: "Uses your own storage now", tone: .neutral)
        case "ended":
            let lost = v.lostFiles == 0 ? "nothing was lost" : "\(v.lostFiles) file\(v.lostFiles == 1 ? "" : "s") held only in its storage were lost"
            return Line(text: "Your plan ended: now only on \(server); \(lost)", tone: v.lostFiles == 0 ? .neutral : .danger)
        case "failed":
            if v.reason == "registered_elsewhere" { return Line(text: "Another server already holds this vault in your account", tone: .danger) }
            return Line(text: "Something went wrong: " + (v.lastError ?? "\(server) retries on its own"), tone: .danger)
        default:
            return Line(text: v.state, tone: .neutral)
        }
    }

    static func waiting(_ reason: String?, server: String) -> String {
        switch reason {
        case "payment_required": "payment needed"
        case "over_quota": "your plan's storage is full"
        case "account_key_unconfirmed": "the recovery key isn't confirmed on \(server)"
        case "bucket_limit": "your account has as many vaults in storage as it can"
        case "pending", "created": "its storage is being prepared"
        case "rotation_requested": "getting a new storage key"
        default: "waiting for its storage"
        }
    }

    static func progress(_ v: Vault) -> String {
        guard let total = v.bytesTotal, total > 0, let done = v.bytesDone else { return "" }
        let percent = Int((Double(done) / Double(total) * 100).rounded(.down))
        var out = ", \(min(percent, 100)) %"
        if let eta = v.etaSeconds, eta > 0 { out += ", about \(duration(eta))" }
        return out
    }

    static func duration(_ seconds: Int64) -> String {
        if seconds < 90 { return "a minute" }
        if seconds < 90 * 60 { return "\((seconds + 30) / 60) minutes" }
        let hours = (seconds + 1800) / 3600
        return hours < 36 ? "\(hours) hours" : "\((hours + 12) / 24) days"
    }

    /// "1.2 TB of 2 TB, as of 2026-11-14", or nil without a figure.
    public static func usage(used: Int64?, quota: Int64?, day: String?) -> String? {
        guard let used else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        let of = quota.map { " of \(f.string(fromByteCount: $0))" } ?? ""
        return "\(f.string(fromByteCount: used))\(of)" + (day.map { ", as of \($0)" } ?? "")
    }

    /// Why storage isn't available on a server, from `cloud.storage.status`.
    public static func unavailable(linked: Bool, accountKey: String, entitlement: String?, server: String) -> String {
        if !linked { return "\(server) isn't connected to Vaulthalla Cloud." }
        switch accountKey {
        case "tampered": return "\(server) found the account's recovery key altered and stopped using it."
        case "pinned": break
        default: return "The recovery key isn't confirmed on \(server) yet: confirm it under Servers."
        }
        return entitlement == nil ? "Your account has no storage plan." : "Storage isn't available on \(server) right now."
    }
}

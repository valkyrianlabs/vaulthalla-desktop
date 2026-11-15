public import Foundation

/// A Desktop-only vault's lines in plain words: who holds it, its storage, this Mac's storage key and its renewal,
/// and the refusals, from `GET /v1/storage` and ``DeviceAccess``. Pure, so every state is a table test. Nothing here
/// says files are stored (Desktop has no sync engine for these vaults yet) or that the service is open.
public enum DeviceAccessWording {
    public typealias Line = ManagedStorageWording.Line

    /// Who writes to the vault: this Mac, another Mac, a server (`server`, from `GET /v1/vaults`' replicas), or nobody.
    public static func holder(_ v: CloudStorage.Vault, thisMac: String, server: String?) -> Line {
        if let moved = v.movedTo {
            return Line(text: "Moved to the server \u{201C}\(moved.name)\u{201D}. This Mac keeps its local copy.", tone: .neutral)
        }
        if let d = v.desktop {
            if d.installationId == thisMac { return Line(text: "Held by this Mac", tone: .ok) }
            return Line(text: "Held by the Mac \u{201C}\(d.name)\u{201D}", tone: .neutral)
        }
        if let server { return Line(text: "Held by the server \u{201C}\(server)\u{201D}", tone: .neutral) }
        return Line(text: "No device holds it yet: the account holder places it in the portal", tone: .neutral)
    }

    /// The vault's bucket, as the cloud reports it.
    public static func bucket(_ v: CloudStorage.Vault) -> Line {
        switch v.state {
        case "ready": Line(text: "Its storage is ready", tone: .ok)
        case "none": Line(text: "Its storage isn't switched on", tone: .neutral)
        case "off": Line(text: "Its storage is switched off", tone: .neutral)
        case "waiting":
            Line(text: "Its storage waits: " + ManagedStorageWording.waiting(v.reason, server: "this account").lowercasedFirst,
                 tone: v.reason == "payment_required" || v.reason == "over_quota" ? .warn : .info)
        case "pending", "created": Line(text: "Its storage is being prepared", tone: .info)
        case "emptying": Line(text: "Its storage is being deleted", tone: .danger)
        case "deleted": Line(text: "Its storage was deleted", tone: .neutral)
        case "ejecting": Line(text: "Its storage is moving to your own storage account", tone: .info)
        case "ejected": Line(text: "Its storage is in your own storage account now", tone: .neutral)
        default: Line(text: v.state, tone: .neutral)
        }
    }

    /// A key's state and renewal, from the cloud's view of it (this Mac's own, or the holding Mac's).
    public static func key(_ k: CloudStorage.KeyView?, now: Date, mine: Bool) -> Line {
        let who = mine ? "This Mac" : "The Mac holding it"
        guard let k, k.state != "none" else { return Line(text: "\(who) has no storage key", tone: .neutral) }
        let access = k.access == "read_delete" ? " (read and delete only)" : ""
        switch k.state {
        case "issued": return Line(text: "\(who) is getting a storage key", tone: .info)
        case "active":
            guard let e = k.expiresAt else { return Line(text: "\(who) has a storage key\(access)", tone: .ok) }
            let expires = date(e)
            guard let r = k.renewAfter else { return Line(text: "Storage key\(access) valid until \(when(expires, now: now))", tone: .ok) }
            let renew = date(r)
            if now >= renew {
                return Line(text: "Storage key\(access) valid until \(when(expires, now: now)); renewal due", tone: .warn)
            }
            return Line(text: "Storage key\(access) valid until \(when(expires, now: now)); renews \(within(renew, now: now))",
                        tone: .ok)
        case "superseded":
            return Line(text: "Storage key being replaced: your plan changed what \(mine ? "this Mac" : "it") may do", tone: .warn)
        case "expired":
            let at = k.expiresAt.map { " at \(when(date($0), now: now))" } ?? ""
            return Line(text: "Storage key expired\(at); \(mine ? "this Mac gets" : "it gets") a new one when online", tone: .warn)
        default: return Line(text: k.state, tone: .neutral)
        }
    }

    /// The renewal loop's state, for a vault this Mac holds.
    public static func status(_ s: DeviceAccess.Status, now: Date) -> Line {
        switch s.phase {
        case .starting: return Line(text: "Checking its storage key", tone: .info)
        case .holding:
            guard let e = s.expiresAt, let r = s.renewAfter else { return Line(text: "Getting a storage key", tone: .info) }
            let access = s.access == "read_delete" ? " (read and delete only)" : ""
            return Line(text: "Storage key\(access) valid until \(when(e, now: now)); renews \(within(r, now: now))", tone: .ok)
        case .waiting(let e): return Line(text: e.message, tone: e == .accountKeyUnconfirmed ? .warn : .info)
        case .paused(let state):
            return Line(text: state == "ended" ? "Your plan ended: no storage access."
                        : "Storage paused: your servers and this Mac can't reach it until payment is updated.", tone: .danger)
        case .retrying(let e, _, let at):
            return Line(text: "\(e.message) Next try \(within(at, now: now)).", tone: .warn)
        case .stopped(let stop): return Self.stop(stop)
        }
    }

    public static func stop(_ s: DeviceAccess.Stop) -> Line {
        switch s {
        case .notHeld(let e): Line(text: e.message, tone: .neutral)
        case .moved(_, let name):
            Line(text: "Moved to the server \u{201C}\(name)\u{201D}. This Mac keeps its local copy and no longer reaches the vault through Vaulthalla Cloud.",
                 tone: .neutral)
        case .keyRevoked: Line(text: "This Mac's storage key was revoked in your account. Get a new one to continue.", tone: .danger)
        case .vaultRemoved: Line(text: "This vault is no longer in your Vaulthalla Cloud account.", tone: .neutral)
        case .unlinked: Line(text: "This Mac isn't linked to Vaulthalla Cloud any more.", tone: .danger)
        case .released: Line(text: "This Mac no longer holds this vault. Its local copy stays.", tone: .neutral)
        case .ejected: Line(text: "Its storage is in your own storage account now.", tone: .neutral)
        }
    }

    static func date(_ seconds: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

    /// "today 14:05", "tomorrow 02:05", or the date.
    static func when(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDate(d, inSameDayAs: now) { return "today \(time)" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "tomorrow \(time)" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    /// "within 3 hours", "within a minute", "now".
    static func within(_ d: Date, now: Date) -> String {
        let s = Int64(d.timeIntervalSince(now))
        return s <= 0 ? "now" : "within \(ManagedStorageWording.duration(s))"
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

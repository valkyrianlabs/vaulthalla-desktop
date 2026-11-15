import Testing
@testable import VHCloud

/// Every managed vault state and waiting reason a server reports, in the words the Storage pane shows.
struct ManagedStorageWordingTests {
    typealias V = ManagedStorageWording.Vault
    func line(_ v: V) -> ManagedStorageWording.Line { ManagedStorageWording.line(v, server: "nas") }

    @Test func statesAndReasons() {
        let table: [(V, String, ManagedStorageWording.Tone)] = [
            (V(storage: "local", switchOn: false, state: "local"), "Only on nas", .neutral),
            (V(storage: "own", switchOn: nil, state: "own"), "Uses its own storage", .neutral),
            (V(storage: "managed", switchOn: true, state: "unregistered", reason: "empty"), "Empty: stored after its first file", .neutral),
            (V(storage: "managed", switchOn: true, state: "waiting", reason: "payment_required"), "Not stored yet: payment needed", .warn),
            (V(storage: "managed", switchOn: true, state: "waiting", reason: "over_quota"), "Not stored yet: your plan's storage is full", .warn),
            (V(storage: "managed", switchOn: true, state: "waiting", reason: "account_key_unconfirmed"),
             "Not stored yet: the recovery key isn't confirmed on nas", .info),
            (V(storage: "managed", switchOn: true, state: "registered", reason: "pending"), "Not stored yet: its storage is being prepared", .info),
            (V(storage: "managed", switchOn: true, state: "attaching", bytesDone: 40, bytesTotal: 100, etaSeconds: 7200),
             "Uploading, 40 %, about 2 hours", .info),
            (V(storage: "managed", switchOn: true, state: "active", access: "full"), "Stored in Vaulthalla Cloud", .ok),
            (V(storage: "managed", switchOn: true, state: "active", access: "read_only"),
             "Read-only: you can open and delete files, not add new ones", .warn),
            (V(storage: "managed", switchOn: true, state: "active", access: "none"),
             "No access: nas can't reach its storage until payment is updated", .danger),
            (V(storage: "managed", switchOn: true, state: "active", reason: "ended_pending_confirmation", access: "none"),
             "Your plan ended: no access until it becomes local on nas", .danger),
            (V(storage: "managed", switchOn: false, state: "detaching", bytesDone: 1, bytesTotal: 4), "Making it local again, 25 %", .info),
            (V(storage: "managed", switchOn: false, state: "off"), "Off: only on nas", .neutral),
            (V(storage: "managed", switchOn: false, state: "moved"), "Moved to another server; nas keeps its local copy", .neutral),
            (V(storage: "managed", switchOn: false, state: "ended", lostFiles: 2),
             "Your plan ended: now only on nas; 2 files held only in its storage were lost", .danger),
            (V(storage: "managed", switchOn: false, state: "ended"), "Your plan ended: now only on nas; nothing was lost", .neutral),
            (V(storage: "managed", switchOn: true, state: "failed", reason: "registered_elsewhere"),
             "Another server already holds this vault in your account", .danger),
        ]
        for (v, text, tone) in table {
            #expect(line(v) == .init(text: text, tone: tone), "\(v.state) \(v.reason ?? "")")
        }
    }

    @Test func usageAndAvailability() {
        #expect(ManagedStorageWording.usage(used: 1_200_000_000_000, quota: 2_000_000_000_000, day: "2026-11-14")
            == "1.2 TB of 2 TB, as of 2026-11-14")
        #expect(ManagedStorageWording.usage(used: nil, quota: 1, day: nil) == nil)
        #expect(ManagedStorageWording.unavailable(linked: false, accountKey: "unlinked", entitlement: nil, server: "nas")
            == "nas isn't connected to Vaulthalla Cloud.")
        #expect(ManagedStorageWording.unavailable(linked: true, accountKey: "unconfirmed", entitlement: "active", server: "nas")
            .hasPrefix("The recovery key isn't confirmed"))
        #expect(ManagedStorageWording.unavailable(linked: true, accountKey: "pinned", entitlement: nil, server: "nas")
            == "Your account has no storage plan.")
    }
}

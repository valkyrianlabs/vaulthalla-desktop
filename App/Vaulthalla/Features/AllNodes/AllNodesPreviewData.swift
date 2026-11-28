#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: each preview vault's recent activity, for the All Nodes cards, and the two preview servers'
/// `peer.*` answers for linking. Restricted accounts see only the vaults they own (none in the preview), so they get
/// the daemon's refusal.
///
/// Linking: "Home lab" is linked with one server and this Mac is a super admin there; "Studio" answers as an account
/// that isn't one, so All Nodes suggests linking them and the sheet offers Request a Link. Flags for pictures:
/// - `-VHDebugLinkOlder YES`: Studio as a Vaulthalla older than 1.27 (no `peer.*` commands).
/// - `-VHDebugLinkBoth YES`: a super admin on Studio too, so the sheet offers the one-screen handshake, which completes
///   between the two preview transports; `-VHDebugLinkRoleRefused YES` has Studio refuse the chosen role.
/// - `-VHDebugLinkRequest waiting|nowindow|linked|denied`: how a request from Home lab ends (waiting by default).
/// - `-VHDebugLinkAccept busy`: Home lab's window is taken. Otherwise its Accept a Link Request lists one request,
///   from "Basement NAS (preview)", whose code is 730 154.
nonisolated enum AllNodesPreviewData: PreviewFeature {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        if command == .storageVaultAccessibleList, transport.scenario == .restricted {
            return Ws.Storage.Vault.Accessible.List.Response(vaults: [])
        }
        switch command {
        case .peerList: return try peers(transport)
        case .rolesVaultList where transport.scenario == .restricted && both:
            return try decode(Ws.Roles.Vault.List.Response.self, #"{"roles": [\#(role(1, "implicit_deny")), \#(role(2, "reader")), \#(role(4, "editor"))]}"#)
        case .peerPairingOpen, .peerPairingPending, .peerPairingApprove, .peerPairingDeny, .peerPairingClose,
             .peerLinkStart, .peerLinkStatus, .peerLinkCancel, .peerPolicySet:
            return try linking(command, payload, transport)
        default: break
        }
        guard command == .statsVaultActivity else { return nil }
        guard transport.scenario == .full else { throw .denied("Permission denied: you don't own this vault.") }
        let id = (payload as? Ws.Stats.Vault.Activity.Payload)?.vaultID ?? 0
        return Ws.Stats.Vault.Activity.Response(stats: activity(id))
    }

    // MARK: - Linking

    private static var both: Bool { UserDefaults.standard.bool(forKey: "VHDebugLinkBoth") }

    /// What the two preview servers did, shared by their transports.
    private struct Lab {
        struct Attempt {
            var dialler: PreviewTransport.Scenario
            var brokered: Bool
            var cancelled = false
            var approved = false
        }

        var attempts: [String: Attempt] = [:]
        var linked = false
        var accepted = false
        var nasDenied = false
        var windowOpen: Set<String> = []
    }

    private static let lab = Mutex(Lab())
    private static let code = "418207"
    private static let nasCode = "730154"
    private static let nasKey = String(repeating: "5e17", count: 16)

    private static func key(_ scenario: PreviewTransport.Scenario) -> String {
        String(repeating: scenario == .full ? "ab" : "cd", count: 32)
    }

    private static func serverName(_ scenario: PreviewTransport.Scenario) -> String {
        scenario == .full ? "Home lab (preview)" : "Studio (preview)"
    }

    private static func other(_ scenario: PreviewTransport.Scenario) -> PreviewTransport.Scenario {
        scenario == .full ? .restricted : .full
    }

    private static func tag(_ scenario: PreviewTransport.Scenario) -> String { scenario == .full ? "full" : "restricted" }

    private static func linking(_ command: WsCommand, _ payload: some Sendable, _ transport: PreviewTransport)
        throws(WsError) -> Any
    {
        let me = transport.scenario
        guard me == .full || both else { throw .denied("only super admins may link servers") }
        let now = PreviewData.now
        switch command {
        case .peerPairingOpen:
            if me == .full, UserDefaults.standard.string(forKey: "VHDebugLinkAccept") == "busy" {
                throw .conflict("a pairing window is already open on this node")
            }
            lab.withLock { _ = $0.windowOpen.insert(tag(me)) }
            let host = me == .full ? "10.0.0.33" : "studio.local"
            return try decode(Ws.Peer.Pairing.Open.Response.self, """
                {"window": {"owner_id": 1, "opened_at": \(now), "expires_at": \(now + 600)}, "server_time": \(now),
                 "node_id": "preview-\(tag(me))", "name": "\(serverName(me))", "spki_sha256": "\(key(me))",
                 "endpoints": {"port": 36972, "remote": true, "listening": true, "generated_at": \(now),
                   "candidates": [{"host": "127.0.0.1", "port": 36972, "kind": "loopback"},
                                  {"host": "\(host)", "port": 36972, "kind": "lan"},
                                  {"host": "100.101.1.2", "port": 36972, "kind": "vpn"}]}}
                """)
        case .peerPairingPending:
            let state = lab.withLock { $0 }
            var requests: [String] = []
            if let (id, _) = state.attempts.first(where: { $0.value.brokered && $0.value.dialler != me && !$0.value.approved
                && !$0.value.cancelled })
            {
                requests.append(request(id, from: serverName(other(me)), key: key(other(me)), ip: "192.168.1.40",
                                        choices: ["205118", code, "993407"]))
            }
            if !both, me == .full, !state.accepted, !state.nasDenied {
                requests.append(request("preview-nas", from: "Basement NAS (preview)", key: nasKey, ip: "192.168.1.77",
                                        choices: ["118342", nasCode, "604981"]))
            }
            let open = state.windowOpen.contains(tag(me)) && !(me == .full && state.accepted)
            let window = open ? #"{"owner_id": 1, "opened_at": \#(now), "expires_at": \#(now + 600)}"# : "null"
            return try decode(Ws.Peer.Pairing.Pending.Response.self,
                              #"{"window": \#(window), "requests": [\#(requests.joined(separator: ","))], "server_time": \#(now)}"#)
        case .peerPairingApprove:
            guard let p = payload as? Ws.Peer.Pairing.Approve.Payload else { throw .invalid("Bad payload.") }
            if p.requestID == "preview-nas" {
                guard p.code == nasCode, p.expectSpki?.wrapped == nasKey else {
                    lab.withLock { $0.nasDenied = true }
                    throw .invalid("wrong code: the request was declined")
                }
                lab.withLock { $0.accepted = true; $0.windowOpen.remove(tag(me)) }
                return try decode(Ws.Peer.Pairing.Approve.Response.self,
                                  #"{"peer": \#(row(7, name: "Basement NAS (preview)", key: nasKey, health: false))}"#)
            }
            lab.withLock { lab in
                lab.attempts[p.requestID]?.approved = true
                lab.linked = true
                lab.windowOpen.remove(tag(me))
            }
            return try decode(Ws.Peer.Pairing.Approve.Response.self,
                              #"{"peer": \#(row(2, name: serverName(other(me)), key: key(other(me)), health: false))}"#)
        case .peerPairingDeny:
            if (payload as? Ws.Peer.Pairing.Deny.Payload)?.requestID == "preview-nas" { lab.withLock { $0.nasDenied = true } }
            return try decode(Ws.Peer.Pairing.Deny.Response.self, #"{"denied": true}"#)
        case .peerPairingClose:
            lab.withLock { _ = $0.windowOpen.remove(tag(me)) }
            return try decode(Ws.Peer.Pairing.Close.Response.self, #"{"closed": true}"#)
        case .peerLinkStart:
            let id = lab.withLock { lab -> String in
                let id = "preview-link-\(lab.attempts.count + 1)"
                lab.attempts[id] = Lab.Attempt(dialler: me, brokered: both)
                return id
            }
            return try decode(Ws.Peer.Link.Start.Response.self, #"{"link": \#(link(id, state: "connecting"))}"#)
        case .peerLinkStatus, .peerLinkCancel:
            let id = (payload as? Ws.Peer.Link.Status.Payload)?.linkID ?? (payload as? Ws.Peer.Link.Cancel.Payload)?.linkID ?? ""
            if command == .peerLinkCancel { lab.withLock { $0.attempts[id]?.cancelled = true } }
            guard let attempt = lab.withLock({ $0.attempts[id] }) else { throw .notFound("no link attempt") }
            let json: String
            if attempt.cancelled {
                json = link(id, state: "cancelled")
            } else if attempt.brokered {
                json = attempt.approved ? link(id, state: "linked", peer: other(me), peerID: 2)
                    : link(id, state: "awaiting_approval", code: code, peer: other(me))
            } else {
                switch UserDefaults.standard.string(forKey: "VHDebugLinkRequest") {
                case "nowindow":
                    json = link(id, state: "failed", error: "no window for linking a server is open on this server: open one (`vh peer pair` there), then try again")
                case "linked": json = link(id, state: "linked", peer: other(me), peerID: 3)
                case "denied": json = link(id, state: "denied", error: "the other server declined the link (or its owner picked another code)")
                default: json = link(id, state: "awaiting_approval", code: code, peer: other(me))
                }
            }
            return try decode(Ws.Peer.Link.Status.Response.self, #"{"link": \#(json)}"#)
        case .peerPolicySet:
            if me == .restricted, UserDefaults.standard.bool(forKey: "VHDebugLinkRoleRefused") {
                throw .denied("a linked server's default vault role reaches every vault mirrored with it: it takes vault.roles.assign on every vault")
            }
            guard let p = payload as? Ws.Peer.Policy.Set.Payload else { throw .invalid("Bad payload.") }
            let names: [Int64: String] = [2: "reader", 3: "contributor", 4: "editor", 5: "manager", 6: "full"]
            var roleJSON = "null"
            if case .integer(let id)? = p.role { roleJSON = role(id, names[id] ?? "role \(id)") }
            return try decode(Ws.Peer.Policy.Set.Response.self, """
                {"policy": {"peer": {"id": 2, "node_id": "preview-\(tag(other(me)))", "name": "\(serverName(other(me)))",
                  "revoked": false}, "role": \(roleJSON), "set_by": 1, "set_by_name": "cooper", "set_at": \(now)}}
                """)
        default:
            throw .notFound("The preview has no answer for \(command.rawValue).")
        }
    }

    private static func request(_ id: String, from name: String, key: String, ip: String, choices: [String]) -> String {
        let now = PreviewData.now
        return """
            {"request_id": "\(id)", "node_id": "preview-\(id)", "name": "\(name)", "product_version": "1.27.1",
             "peer_protocol": 1, "spki_sha256": "\(key)", "source_ip": "\(ip)",
             "code_choices": [\(choices.map { "\"\($0)\"" }.joined(separator: ","))],
             "created_at": \(now - 20), "expires_at": \(now + 280)}
            """
    }

    private static func link(_ id: String, state: String, code: String? = nil, peer: PreviewTransport.Scenario? = nil,
                             peerID: Int64? = nil, error: String? = nil) -> String {
        let now = PreviewData.now
        let peerJSON = peer.map {
            #"{"node_id": "preview-\#(tag($0))", "name": "\#(serverName($0))", "product_version": "1.27.1", "spki_sha256": "\#(key($0))"}"#
        } ?? "null"
        func quoted(_ text: String?) -> String { text.map { "\"\($0)\"" } ?? "null" }
        return """
            {"link_id": "\(id)", "state": "\(state)", "code": \(quoted(code)), "peer": \(peerJSON),
             "peer_id": \(peerID.map(String.init) ?? "null"), "expect_spki": null,
             "address": \(state == "connecting" ? "null" : "\"studio.local:36972\""), "error": \(quoted(error)),
             "created_at": \(now), "updated_at": \(now)}
            """
    }

    private static func role(_ id: Int64, _ name: String) -> String {
        let now = PreviewData.now
        return #"{"id": \#(id), "name": "\#(name)", "description": "", "created_at": \#(now), "updated_at": \#(now), "assigned_at": null, "permissions": []}"#
    }

    private static func row(_ id: Int64, name: String, key: String, health: Bool, connected: Bool = true) -> String {
        let now = PreviewData.now
        let healthJSON = """
            , "health": {"connected": \(connected), "since": \(now - 7_200), "dialed_by": "this_server",
              "address": "vault.example.com:36972", "rtt_ms": 38, "peer_protocol": 1, "peer_version": "1.27.1",
              "protocol_compatible": true, "last_error": null, "last_error_at": null, "next_attempt_at": null}
            """
        return """
            {"id": \(id), "node_id": "preview-node-\(id)", "name": "\(name)", "spki_sha256": "\(key)",
             "next_spki_sha256": null, "attest_public_keys": [], "wrap_public_key": "AAAA", "endpoints": [],
             "sharing": "identities", "approved_by": 1, "compared_by": "desktop", "peer_protocol": 1,
             "product_version": "1.27.1", "linked_at": \(now - 86_400 * 3), "last_seen_at": \(now - 30),
             "revoked_at": null, "revoked": false\(health ? healthJSON : "")}
            """
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws(WsError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw .contractMismatch("preview \(T.self): \(error)")
        }
    }

    /// "Home lab" is linked with one server (and with Studio once linked here); Studio answers as an account that
    /// isn't a super admin unless `-VHDebugLinkBoth`, or with `-VHDebugLinkOlder YES` as a Vaulthalla older than 1.27.
    private static func peers(_ transport: PreviewTransport) throws(WsError) -> Ws.Peer.List.Response {
        let linked = lab.withLock { $0.linked }
        var rows: [String]
        if transport.scenario == .full {
            rows = [row(1, name: "Offsite (preview)", key: String(repeating: "ef", count: 32), health: true)]
            if linked { rows.append(row(2, name: "Studio (preview)", key: key(.restricted), health: true)) }
        } else {
            if UserDefaults.standard.bool(forKey: "VHDebugLinkOlder") { throw .unknownCommand("Unknown command") }
            guard both else { throw .denied("only super admins may link servers") }
            rows = linked ? [row(2, name: "Home lab (preview)", key: key(.full), health: true)] : []
        }
        return try decode(Ws.Peer.List.Response.self, #"{"peers": [\#(rows.joined(separator: ","))]}"#)
    }

    private static let samples: [Int64: [(action: String, path: String, minutesAgo: Int64)]] = [
        1: [("upload", "/2026/10/IMG_4182.HEIC", 4), ("upload", "/2026/10/IMG_4181.HEIC", 5), ("rename", "/Albums/Lake", 52)],
        2: [("upload", "/Taxes/2026-estimates.pdf", 18), ("delete", "/Scratch/old-draft.docx", 95)],
        3: [("upload", "/nightly/documents-2026-11-01.tar.zst", 240)],
        4: [("restore", "/projects/aurora/final.mov", 610)],
    ]

    private static func activity(_ id: Int64) -> WsModel.VaultActivity {
        let now = PreviewData.now
        let events = samples[id] ?? []
        let uploads = Int64(events.filter { $0.action == "upload" }.count) * (id == 1 ? 21 : 3)
        return WsModel.VaultActivity(
            vaultID: id, lastActivityAt: events.first.map { now - $0.minutesAgo * 60 },
            lastActivityAction: events.first?.action, uploads24h: uploads, uploads7d: uploads * 6,
            deletes24h: Int64(events.filter { $0.action == "delete" }.count), deletes7d: 4, renames24h: id == 1 ? 1 : 0,
            renames7d: 2, moves24h: 0, moves7d: 1, copies24h: 0, copies7d: 0,
            restores24h: Int64(events.filter { $0.action == "restore" }.count), restores7d: 1,
            bytesAdded24h: uploads * 3_400_000, bytesRemoved24h: 1_200_000, topActiveUsers: [], topTouchedPaths: [],
            recentActivity: events.map {
                .init(source: "fs", action: $0.action, path: $0.path, userName: "cooper", bytes: 3_400_000,
                      occurredAt: now - $0.minutesAgo * 60)
            },
            checkedAt: now)
    }
}
#endif

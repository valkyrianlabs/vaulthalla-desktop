import CryptoKit
import Foundation
@testable import VHCloud
import VHKeykit
import VHRecovery

/// Enough of the Vaulthalla Cloud daemon (main, src/accounts, src/keys, src/billing, src/recovery) to check Desktop's
/// side, with the daemon's own checks where Desktop's correctness depends on them: link proofs (v2) and VHC1
/// signatures verified with the registered key, key chains verified with vl-keykit, holder proofs verified, KAK1
/// prefixes checked against the current generation and the addressed key, request codes from id and payload, and the
/// daemon's JSON shapes. It is a fake: what runs against it is stated as such.
final class FakeCloud: CloudTransport, @unchecked Sendable {
    let lock = NSLock()
    let installation = "kceypk9vfn5tv6yx5c6qpfebdm"
    let publicID = "5f0c3a3e-8d1b-4c2a-9e47-6b1d2f3a4c5e"
    var linkKey: Data?
    var claimAnswer = "pending"
    var calls: [String] = []
    /// Answers the next signed request with this status and code (402, 429...).
    var failNext: (status: Int, code: String, retryAfter: String?)?

    // The account key.
    struct Generation {
        var signed: SignedStatement
        var reason: String
        var link: String
        var confirmedAt: Int64?
    }

    var chain: [Generation] = []
    struct Holder {
        var installation: String
        var suite: UInt16
        var key: Data
        var generation: UInt32
        var proof: Data
        var kak1: Data
    }

    var holders: [Holder] = []
    struct Request {
        var id: String
        var action: String
        var payload: String
        var status = "requested"
    }

    var requests: [Request] = []
    struct Transfer {
        var id: String
        var requester: String
        var suite: UInt16
        var key: Data
        var status = "requested"
        var kak1: Data?
    }

    var transfers: [Transfer] = []

    // The account's servers and vaults, billing.
    var deployments: [[String: Any]] = []
    var vaults: [[String: Any]] = []
    var billingState: [String: Any] = ["state": NSNull(), "plan": "free", "storage_quota_bytes": 0,
                                       "recovery_vaults": ["allowance": 10, "enrolled": NSNull()], "storage_access": "none",
                                       "next": NSNull(), "deletion_at": NSNull(), "current_period_end": NSNull(),
                                       "cancel_at_period_end": false]
    var handoffKinds: [String] = []

    // Restores.
    var restoreSummary: [String: Any] = [:]
    var envelopes: [String] = []
    var keyVersions: [UInt32] = []
    var bundle: [String]?
    var lieAboutTheCode = false

    private var counter = 0
    func newID() -> String {
        counter += 1
        let digits = String(counter)
        return String("0123456789abcdefghjkmnpqrs".dropLast(digits.count)) + digits
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try lock.withLock { try handle(request) }
    }

    // MARK: what the portal and other devices do

    /// The account holder approves a key request in the portal (with its step-up): the daemon applies it.
    func approve(_ id: String) throws {
        try lock.withLock {
            guard let i = requests.firstIndex(where: { $0.id == id }) else { throw CloudError.notFound(id) }
            let r = requests[i]
            let payload = try JSONSerialization.jsonObject(with: Data(r.payload.utf8)) as! [String: Any]
            switch r.action {
            case "create", "rotate":
                let signed = SignedStatement(statement: payload["statement"] as! String,
                                             signature: Base64URL.decode(payload["signature"] as! String)!,
                                             previousSignature: (payload["previous_signature"] as? String).flatMap(Base64URL.decode))
                let verified = try KeyChain.verify(chain.map(\.signed) + [signed], publicID: publicID)
                let statement = try KeyStatement(signed.statement)
                let confirmed = (payload["offline_copy_confirmed"] as? Bool) == true ? Int64(Date.now.timeIntervalSince1970) : nil
                chain.append(Generation(signed: signed, reason: statement.reason.name,
                                        link: ["initial", "rotation", "replacement"][Int(verified.last!.link.rawValue)],
                                        confirmedAt: confirmed))
                // Holders listed are resealed for the new generation; the rest are dropped.
                var kept: [Holder] = []
                for h in payload["holders"] as? [[String: Any]] ?? [] {
                    guard var holder = holders.first(where: { $0.installation == h["installation_id"] as? String }) else { continue }
                    holder.proof = Base64URL.decode(h["proof"] as! String)!
                    holder.kak1 = Base64URL.decode(h["kak1"] as! String)!
                    try HolderProof.verify(holder.proof, statement: statement, installationID: holder.installation,
                                           suite: KeySuite(rawValue: holder.suite)!, holderPublicKey: holder.key)
                    try checkKak1(holder.kak1, statement: statement, key: holder.key, suite: holder.suite)
                    holder.generation = statement.generation
                    kept.append(holder)
                }
                holders = kept
            case "offline_copy":
                chain[chain.count - 1].confirmedAt = Int64(Date.now.timeIntervalSince1970)
            default: break
            }
            requests[i].status = "approved"
        }
    }

    func deny(_ id: String) { lock.withLock { requests[requests.firstIndex { $0.id == id }!].status = "denied" } }

    /// Another device asks for the key (its temporary key).
    func otherDeviceRequestsTransfer(key: Data, suite: UInt16 = 2) -> String {
        lock.withLock {
            let id = newID()
            transfers.append(Transfer(id: id, requester: "installation:other", suite: suite, key: key))
            return id
        }
    }

    /// Another holder delivers the transfer this Mac asked for.
    func otherHolderDelivers(_ id: String, kak1: Data) {
        lock.withLock {
            let i = transfers.firstIndex { $0.id == id }!
            transfers[i].status = "delivered"
            transfers[i].kak1 = kak1
        }
    }

    /// The account key created in the portal (by the browser), generation 1.
    func portalCreatesKey(_ key: AccountKey) throws {
        let statement = try key.statement(publicID: publicID, generation: 1, previous: nil, reason: .initial)
        lock.withLock { chain = [Generation(signed: try! key.sign(statement), reason: "initial", link: "initial")] }
    }

    var current: KeyStatement? { chain.last.map { try! KeyStatement($0.signed.statement) } }

    // MARK: routing

    private func checkKak1(_ kak1: Data, statement: KeyStatement, key: Data, suite: UInt16) throws {
        let h = try KAK1Header(kak1)
        guard h.suite == suite, h.publicID == statement.publicID, h.generation == statement.generation,
              h.fingerprint == statement.fingerprint.bytes, h.recipientID == (try Keykit.recipientID(of: key))
        else { throw CloudError.invalid("kak1") }
    }

    private func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let method = request.httpMethod!
        calls.append("\(method) \(path)")
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func reply(_ status: Int, _ json: Any, headers: [String: String]? = nil) -> (Data, HTTPURLResponse) {
            (status == 204 ? Data() : try! JSONSerialization.data(withJSONObject: json),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        func refuse(_ status: Int, _ code: String, _ message: String) -> (Data, HTTPURLResponse) {
            reply(status, ["error": ["code": code, "message": message]])
        }
        if path == "/v1/link-requests" {
            let pkText = body["public_key"] as! String
            linkKey = Base64URL.decode(pkText)
            let proof = Base64URL.decode(body["proof"] as! String)!
            let message = Data("vhc-link-request-v2\n\(pkText)\n\(body["name"] as! String)\n\(body["kind"] as! String)\n\(body["node_id"] as! String)".utf8)
            guard body["kind"] as? String == "desktop", body["node_id"] as? String == "",
                  try Curve25519.Signing.PublicKey(rawRepresentation: linkKey!).isValidSignature(proof, for: message)
            else { return refuse(400, "invalid_argument", "bad proof") }
            return reply(201, ["request_id": "0123456789abcdefghjkmnpqrs", "user_code": "WXYZ-1234", "expires_at": 4102444800])
        }
        if path.hasSuffix("/claim") {
            let ts = (body["timestamp"] as! NSNumber).int64Value
            let message = Data("vhc-link-claim-v1\n0123456789abcdefghjkmnpqrs\n\(ts)".utf8)
            guard try Curve25519.Signing.PublicKey(rawRepresentation: linkKey!)
                .isValidSignature(Base64URL.decode(body["signature"] as! String)!, for: message)
            else { return refuse(401, "unauthenticated", "bad claim") }
            if claimAnswer == "linked" {
                return reply(200, ["status": "linked", "installation_id": installation, "account_id": 7,
                                   "account_public_id": publicID])
            }
            return reply(200, ["status": claimAnswer])
        }
        // Everything else is signed as the installation.
        guard verifies(request) else { return refuse(401, "unauthenticated", "request signature rejected") }
        if let f = failNext {
            failNext = nil
            return reply(f.status, ["error": ["code": f.code, "message": "refused for the test"]],
                         headers: f.retryAfter.map { ["Retry-After": $0] })
        }
        var summary = restoreSummary
        if lieAboutTheCode { summary["restore_code"] = "0000-0000-0000-0000" }
        let parts = path.split(separator: "/").map(String.init)
        switch (method, path) {
        case ("GET", "/v1/installation"):
            return reply(200, ["id": installation, "account_id": 7, "account_public_id": publicID, "deployment_id": NSNull(),
                               "name": "MacBook", "kind": "desktop", "public_key": Base64URL.encode(linkKey!)])
        case ("GET", "/v1/deployments"): return reply(200, ["deployments": deployments])
        case ("GET", "/v1/vaults"): return reply(200, ["vaults": vaults])
        case ("GET", "/v1/billing"): return reply(200, billingState)
        case ("GET", "/v1/billing/plans"):
            return reply(200, ["plans": [["plan": "storage_1tb", "storage_quota_bytes": 1_000_000_000_000,
                                          "recovery_vaults": "unlimited", "prices": []]]])
        case ("POST", "/v1/billing/handoffs"):
            handoffKinds.append(body["kind"] as! String)
            return reply(201, ["id": newID(), "url": "https://app.vaulthalla.test/billing/handoff#h1", "expires_at": 4102444800])
        case ("GET", "/v1/keys/account"):
            guard !chain.isEmpty else { return refuse(404, "not_found", "this account has no recovery key yet") }
            let entries: [[String: Any]] = chain.enumerated().map { i, g in
                let s = try! KeyStatement(g.signed.statement)
                return ["generation": s.generation, "statement": g.signed.statement, "signature": Base64URL.encode(g.signed.signature),
                        "previous_signature": g.signed.previousSignature.map { Base64URL.encode($0) } ?? NSNull(),
                        "fingerprint": s.fingerprint.text, "reason": g.reason, "link": g.link,
                        "status": i == chain.count - 1 ? "current" : "retired", "created_at": 1, "retired_at": NSNull(),
                        "offline_copy_confirmed_at": g.confirmedAt ?? NSNull()]
            }
            let last = entries.last!
            return reply(200, ["public_id": publicID,
                               "current": ["generation": last["generation"]!, "fingerprint": last["fingerprint"]!,
                                           "link": last["link"]!, "offline_copy_confirmed_at": last["offline_copy_confirmed_at"]!],
                               "offline_copy_confirmed_at": last["offline_copy_confirmed_at"]!, "chain": entries,
                               "policy": NSNull()])
        case ("GET", "/v1/keys/holders"):
            return reply(200, ["holders": holders.map { h -> [String: Any] in
                var j: [String: Any] = ["installation_id": h.installation, "suite": h.suite,
                                        "holder_public_key": Base64URL.encode(h.key), "generation": h.generation,
                                        "proof": Base64URL.encode(h.proof), "added_at": 1, "updated_at": 1]
                if h.installation == installation { j["kak1"] = Base64URL.encode(h.kak1) }
                return j
            }])
        case ("POST", "/v1/keys/holders"):
            guard let current else { return refuse(409, "conflict", "no key") }
            let suite = UInt16(body["suite"] as! Int)
            let key = Base64URL.decode(body["holder_public_key"] as! String)!
            guard UInt32(body["generation"] as! Int) == current.generation else { return refuse(409, "conflict", "sign for it") }
            let proof = Base64URL.decode(body["proof"] as! String)!
            let kak1 = Base64URL.decode(body["kak1"] as! String)!
            do {
                try HolderProof.verify(proof, statement: current, installationID: installation, suite: KeySuite(rawValue: suite)!,
                                       holderPublicKey: key)
                try checkKak1(kak1, statement: current, key: key, suite: suite)
            } catch {
                return refuse(400, "invalid_argument", "\(error)")
            }
            holders.removeAll { $0.installation == installation }
            holders.append(Holder(installation: installation, suite: suite, key: key, generation: current.generation,
                                  proof: proof, kak1: kak1))
            return reply(201, ["installation_id": installation, "suite": suite, "holder_public_key": Base64URL.encode(key),
                               "generation": current.generation, "proof": Base64URL.encode(proof), "added_at": 1,
                               "updated_at": 1, "kak1": Base64URL.encode(kak1)])
        case ("POST", "/v1/keys/requests"):
            let r = Request(id: newID(), action: body["action"] as! String, payload: body["payload"] as! String)
            requests.append(r)
            return reply(201, requestJSON(r))
        case ("GET", _) where parts.count == 4 && parts[1] == "keys" && parts[2] == "requests":
            guard let r = requests.first(where: { $0.id == parts[3] }) else { return refuse(404, "not_found", "no such key request") }
            return reply(200, requestJSON(r))
        case ("POST", "/v1/keys/transfers"):
            let t = Transfer(id: newID(), requester: "installation:\(installation)", suite: UInt16(body["suite"] as! Int),
                             key: Base64URL.decode(body["temporary_public_key"] as! String)!)
            transfers.removeAll { $0.requester == t.requester && $0.status == "requested" }
            transfers.append(t)
            return reply(201, transferJSON(t))
        case ("GET", "/v1/keys/transfers/pending"):
            guard holders.contains(where: { $0.installation == installation && $0.generation == current?.generation })
            else { return refuse(403, "forbidden", "this installation doesn't hold the account key") }
            return reply(200, ["transfers": transfers.filter { $0.status == "requested" && $0.requester != "installation:\(installation)" }
                .map(transferJSON)])
        case ("GET", _) where parts.count == 4 && parts[2] == "transfers":
            guard let t = transfers.first(where: { $0.id == parts[3] && $0.requester == "installation:\(installation)" })
            else { return refuse(404, "not_found", "no such key transfer") }
            var j = transferJSON(t)
            if let kak1 = t.kak1 { j["kak1"] = Base64URL.encode(kak1) }
            return reply(200, j)
        case ("POST", _) where parts.count == 5 && parts[2] == "transfers":
            guard let i = transfers.firstIndex(where: { $0.id == parts[3] }) else { return refuse(404, "not_found", "no such") }
            switch parts[4] {
            case "deliver":
                let kak1 = Base64URL.decode(body["kak1"] as! String)!
                do { try checkKak1(kak1, statement: current!, key: transfers[i].key, suite: transfers[i].suite) } catch {
                    return refuse(400, "invalid_argument", "bad kak1")
                }
                transfers[i].status = "delivered"
                transfers[i].kak1 = kak1
                return reply(200, transferJSON(transfers[i]))
            case "complete": transfers[i].status = "completed"; transfers[i].kak1 = nil
            default: transfers[i].status = "cancelled"; transfers[i].kak1 = nil
            }
            return reply(204, [:])
        case ("GET", "/v1/recovery/restores/deliverable"): return reply(200, ["restores": [summary]])
        case ("GET", _) where path.hasSuffix("/source"):
            summary["envelopes"] = envelopes
            summary["key_versions"] = keyVersions.map { ["version": $0, "key_check": "kc"] }
            return reply(200, summary)
        case ("POST", _) where path.hasSuffix("/bundle"):
            bundle = body["envelopes"] as? [String]
            return reply(200, summary)
        case ("DELETE", "/v1/installation"):
            holders.removeAll { $0.installation == installation }
            return reply(204, [:])
        default: return refuse(404, "not_found", "no route \(method) \(path)")
        }
    }

    private func requestJSON(_ r: Request) -> [String: Any] {
        ["id": r.id, "action": r.action, "status": r.status, "request_code": try! KeyCodes.request(id: r.id, payload: r.payload),
         "requester": ["installation_id": installation, "name": "MacBook", "fingerprint": "aaaa-bbbb-cccc-dddd"],
         "created_at": 1, "expires_at": 4102444800, "closed_at": NSNull()]
    }

    private func transferJSON(_ t: Transfer) -> [String: Any] {
        ["id": t.id, "status": t.status, "suite": t.suite, "temporary_public_key": Base64URL.encode(t.key),
         "transfer_code": try! KeyCodes.transfer(publicID: publicID, temporaryKey: t.key),
         "requester": ["id": t.requester, "name": "Other Mac"], "delivered_by": NSNull(), "created_at": 1,
         "expires_at": 4102444800]
    }

    private func verifies(_ r: URLRequest) -> Bool {
        guard let auth = r.value(forHTTPHeaderField: "Authorization"), let pk = linkKey,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk) else { return false }
        var fields: [String: String] = [:]
        for part in auth.dropFirst("VHC1-Ed25519 ".count).split(separator: ",") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        let body = r.httpBody ?? Data()
        guard r.value(forHTTPHeaderField: VHC1.contentHashHeader) == VHC1.sha256Hex(body),
              fields["Installation"] == installation, let ts = fields["Timestamp"].flatMap(Int64.init),
              let sig = fields["Signature"].flatMap(Base64URL.decode) else { return false }
        let f = VHC1.Fields(method: r.httpMethod!, path: r.url!.path, query: r.url!.query ?? "", host: "api.vaulthalla.test",
                            installation: installation, timestamp: ts, nonce: fields["Nonce"] ?? "",
                            bodySHA256: VHC1.sha256Hex(body))
        return key.isValidSignature(sig, for: Data(VHC1.stringToSign(f).utf8))
    }
}

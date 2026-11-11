import CryptoKit
public import Foundation
public import VHRecovery
import VHCore

/// How Desktop reaches Vaulthalla Cloud: URLSession, or a fake in tests.
public protocol CloudTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionCloudTransport: CloudTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.unreachable("not an HTTP response") }
        return (data, http)
    }
}

public enum CloudError: Error, Sendable, Equatable {
    case invalidEndpoint(String)
    case unreachable(String)
    case refused(status: Int, message: String)
    case notLinked
    case malformed(String)
    /// The cloud's restore code isn't the one Desktop computes from the temporary key it was given.
    case restoreCodeMismatch
    /// Nothing in the vault's records opens with this recovery kit.
    case noEnvelopeOpens
}

/// Vaulthalla Cloud's installation API as Desktop uses it: linking this Mac as a `desktop` installation and the
/// delivering side of the restore relay (the cloud's docs/design/installation-linking.md and recovery-restore.md).
public struct CloudClient: Sendable {
    public let base: URL
    public let host: String
    let transport: any CloudTransport
    let store: any CloudLinkStore

    /// `endpoint` is https://host[:port] (http only to localhost, for development).
    public init(endpoint: String, store: any CloudLinkStore, transport: any CloudTransport = URLSessionCloudTransport()) throws {
        guard var c = URLComponents(string: endpoint), let scheme = c.scheme?.lowercased(), let h = c.host?.lowercased(),
              c.path.isEmpty || c.path == "/", c.query == nil, c.user == nil
        else { throw CloudError.invalidEndpoint(endpoint) }
        let loopback = h == "localhost" || h == "127.0.0.1" || h == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else { throw CloudError.invalidEndpoint(endpoint) }
        c.path = ""
        c.scheme = scheme
        c.host = h
        if scheme == "https", c.port == 443 { c.port = nil }
        guard let url = c.url else { throw CloudError.invalidEndpoint(endpoint) }
        base = url
        host = c.port.map { "\(h):\($0)" } ?? h
        self.transport = transport
        self.store = store
    }

    // MARK: linking

    public struct LinkStarted: Sendable, Equatable {
        public let userCode: String
        public let fingerprint: String
        public let expiresAt: Date
    }

    /// Starts linking this Mac with a fresh identity key (replacing a pending request). The account holder enters
    /// `userCode` on vaulthalla.cloud and compares `fingerprint`.
    public func startLink(name: String) async throws -> LinkStarted {
        let key = Curve25519.Signing.PrivateKey()
        let pk = Base64URL.encode(key.publicKey.rawRepresentation)
        let proof = try key.signature(for: Data("vhc-link-request-v1\n\(pk)\n\(name)\ndesktop".utf8))
        let reply = try await call("POST", "/v1/link-requests",
                                   body: ["public_key": pk, "name": name, "kind": "desktop", "proof": Base64URL.encode(proof)])
        guard let requestID = reply["request_id"] as? String, let code = reply["user_code"] as? String else {
            throw CloudError.malformed("the link request's answer")
        }
        try store.save(CloudLink(endpoint: base.absoluteString, name: name, state: .pending,
                                 identityKey: key.rawRepresentation.base64EncodedString(), requestID: requestID))
        let expires = (reply["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .now + 600
        return LinkStarted(userCode: code, fingerprint: VHC1.fingerprint(key.publicKey.rawRepresentation), expiresAt: expires)
    }

    public enum ClaimStatus: String, Sendable { case pending, linked, denied, expired }

    /// Asks whether the pending request was decided, signing with the same key. A denied or expired request forgets
    /// the key.
    public func claimLink(now: Date = .now) async throws -> ClaimStatus {
        guard var link = try store.load(), link.state == .pending, let requestID = link.requestID else { throw CloudError.notLinked }
        let key = try identityKey(link)
        let ts = Int64(now.timeIntervalSince1970)
        let signature = try key.signature(for: Data("vhc-link-claim-v1\n\(requestID)\n\(ts)".utf8))
        let reply = try await call("POST", "/v1/link-requests/\(requestID)/claim",
                                   body: ["timestamp": ts, "signature": Base64URL.encode(signature)])
        guard let status = (reply["status"] as? String).flatMap(ClaimStatus.init(rawValue:)) else {
            throw CloudError.malformed("the claim's answer")
        }
        switch status {
        case .linked:
            guard let installation = reply["installation_id"] as? String,
                  let account = (reply["account_id"] as? NSNumber)?.int64Value
            else { throw CloudError.malformed("the claim's answer") }
            link.state = .linked
            link.requestID = nil
            link.installationID = installation
            link.accountID = account
            try store.save(link)
        case .denied, .expired:
            try store.delete()
        case .pending:
            break
        }
        return status
    }

    /// Unlinks this Mac: revokes the installation in the cloud (best effort), then forgets the key.
    public func unlink() async throws {
        if let link = try store.load(), link.state == .linked {
            _ = try? await signedCall("DELETE", "/v1/installation")
        }
        try store.delete()
    }

    // MARK: restores (the delivering side)

    public struct Restore: Sendable, Equatable {
        public let id: String
        public let vaultUid: String
        public let requesterName: String
        public let requesterKind: String
        public let requesterFingerprint: String
        public let temporaryPublicKey: Data
        /// Computed here from the temporary key; the person compares it with the receiving server's.
        public let restoreCode: String
    }

    /// Restores of this account awaiting delivery (approved, requested by another installation).
    public func deliverable() async throws -> [Restore] {
        let reply = try await signedCall("GET", "/v1/recovery/restores/deliverable")
        return try (reply["restores"] as? [[String: Any]] ?? []).map(restore)
    }

    public struct Delivered: Sendable, Equatable {
        public let versions: [UInt32]   // the key versions delivered
        public let missing: [UInt32]    // versions the cloud knows that this kit didn't open
    }

    /// Delivers restore `id` from a recovery kit: opens the vault's stored envelopes with the kit's recipient and
    /// re-wraps each key version to the restore's temporary key. Call it only after the person confirmed that the
    /// receiving server shows `restore.restoreCode`.
    public func deliver(_ restore: Restore, kit: RecoveryKit) async throws -> Delivered {
        let source = try await signedCall("GET", "/v1/recovery/restores/\(restore.id)/source")
        let fresh = try self.restore(source)
        guard fresh.temporaryPublicKey == restore.temporaryPublicKey, fresh.vaultUid == restore.vaultUid else {
            throw CloudError.restoreCodeMismatch  // the key changed since the person compared the code
        }
        guard let uid = Uid(base32: restore.vaultUid) else { throw CloudError.malformed("the vault uid") }
        let recipient = kit.seed.recipient()
        var keys: [UInt32: SecretBytes] = [:]
        for case let text as String in source["envelopes"] as? [Any] ?? [] {
            guard let env = Data(base64Encoded: text) else { continue }
            if let opened = try? KEV1.unwrap(env, recipient: recipient, vaultUid: uid), keys[opened.keyVersion] == nil {
                keys[opened.keyVersion] = opened.key
            }
        }
        guard !keys.isEmpty else { throw CloudError.noEnvelopeOpens }
        var bundle: [String] = []
        for (version, key) in keys.sorted(by: { $0.key < $1.key }) {
            bundle.append(try KEV1.wrap(vaultKey: key, suite: .x25519, keyVersion: version, vaultUid: uid,
                                        recipientPublicKey: restore.temporaryPublicKey).base64EncodedString())
        }
        _ = try await signedCall("POST", "/v1/recovery/restores/\(restore.id)/bundle", body: ["envelopes": bundle])
        let known = (source["key_versions"] as? [[String: Any]] ?? []).compactMap { ($0["version"] as? NSNumber)?.uint32Value }
        return Delivered(versions: keys.keys.sorted(), missing: known.filter { keys[$0] == nil }.sorted())
    }

    // MARK: plumbing

    private func restore(_ j: [String: Any]) throws -> Restore {
        guard let id = j["id"] as? String, let uid = j["vault_uid"] as? String,
              let pkText = j["temporary_public_key"] as? String, let pk = Data(base64Encoded: pkText), pk.count == 32,
              let requester = j["requester"] as? [String: Any]
        else { throw CloudError.malformed("a restore") }
        let code = RestoreCode.of(vaultUid: uid, temporaryPublicKey: pk)
        if let claimed = j["restore_code"] as? String, claimed != code { throw CloudError.restoreCodeMismatch }
        return Restore(id: id, vaultUid: uid, requesterName: requester["name"] as? String ?? "?",
                       requesterKind: requester["kind"] as? String ?? "?",
                       requesterFingerprint: requester["fingerprint"] as? String ?? "?", temporaryPublicKey: pk,
                       restoreCode: code)
    }

    private func identityKey(_ link: CloudLink) throws -> Curve25519.Signing.PrivateKey {
        guard let raw = Data(base64Encoded: link.identityKey),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else { throw CloudError.malformed("the stored identity key") }
        return key
    }

    private func request(_ method: String, _ path: String, body: [String: Any]?) throws -> (URLRequest, Data) {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            r.httpBody = data
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        r.timeoutInterval = 30
        return (r, data)
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let (r, _) = try request(method, path, body: body)
        return try await perform(r)
    }

    private func signedCall(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let link = try store.load(), link.state == .linked, let installation = link.installationID else {
            throw CloudError.notLinked
        }
        var (r, data) = try request(method, path, body: body)
        let q = path.firstIndex(of: "?")
        let fields = VHC1.Fields(method: method, path: q.map { String(path[..<$0]) } ?? path,
                                 query: q.map { String(path[path.index(after: $0)...]) } ?? "", host: host,
                                 installation: installation, timestamp: Int64(Date.now.timeIntervalSince1970),
                                 nonce: VHC1.newNonce(), bodySHA256: VHC1.sha256Hex(data))
        for (k, v) in try VHC1.headers(fields, key: identityKey(link)) { r.setValue(v, forHTTPHeaderField: k) }
        return try await perform(r)
    }

    private func perform(_ r: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(r)
        } catch {
            throw CloudError.unreachable(String(describing: error))
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200 ..< 300).contains(response.statusCode) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(response.statusCode)"
            throw CloudError.refused(status: response.statusCode, message: message)
        }
        return json
    }
}

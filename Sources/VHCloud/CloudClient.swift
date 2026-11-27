import CryptoKit
public import Foundation
public import VHKeykit
import OSLog
import VHCore
public import VHRecovery

/// Vaulthalla Cloud's installation API as Desktop uses it, signed VHC1-Ed25519 by this Mac's identity key: linking
/// (installation-linking.md), the account's reads, the account key's holders, key requests and transfers
/// (key-manager.md), restore delivery (recovery-restore.md) and billing hand-offs (billing.md). Shapes follow the
/// daemon's code (vaulthalla-cloud main).
public struct CloudClient: Sendable {
    public let base: URL
    public let host: String
    let transport: any CloudTransport
    let store: any CloudLinkStore

    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "cloud")

    /// `endpoint` is https://host[:port] (http only to localhost, for development).
    public init(endpoint: String, store: any CloudLinkStore, transport: any CloudTransport) throws {
        guard var c = URLComponents(string: endpoint), let scheme = c.scheme?.lowercased(), let h = c.host?.lowercased(),
              c.path.isEmpty || c.path == "/", c.query == nil, c.user == nil, c.fragment == nil
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

    public func link() throws -> CloudLink? { try store.load() }

    // MARK: linking

    public struct LinkStarted: Sendable, Equatable {
        public let requestID: String
        public let userCode: String
        public let fingerprint: String
        public let expiresAt: Date
    }

    /// Starts linking this Mac with a fresh identity key (replacing a pending request). The account holder enters
    /// `userCode` in the portal and compares `fingerprint`.
    public func startLink(name: String) async throws -> LinkStarted {
        let key = Curve25519.Signing.PrivateKey()
        let pk = Base64URL.encode(key.publicKey.rawRepresentation)
        // A Desktop's node id is empty (proof v2, installation-linking.md).
        let proof = try key.signature(for: Data("vhc-link-request-v2\n\(pk)\n\(name)\ndesktop\n".utf8))
        struct Body: Encodable { var publicKey, name, kind, nodeId, proof: String }
        struct Reply: Decodable { var requestId: String; var userCode: String; var expiresAt: Int64? }
        let reply: Reply = try await call("POST", "/v1/link-requests",
                                          body: Body(publicKey: pk, name: name, kind: "desktop", nodeId: "",
                                                     proof: Base64URL.encode(proof)))
        try store.save(CloudLink(endpoint: base.absoluteString, name: name, state: .pending,
                                 identityKey: key.rawRepresentation.base64EncodedString(), requestID: reply.requestId))
        let expires = reply.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .now + 600
        return LinkStarted(requestID: reply.requestId, userCode: reply.userCode,
                           fingerprint: VHC1.fingerprint(key.publicKey.rawRepresentation), expiresAt: expires)
    }

    public enum ClaimStatus: String, Sendable { case pending, linked, denied, expired }

    /// Asks whether the pending request was decided, signing with the same key. A denied or expired request forgets
    /// the key.
    public func claimLink(now: Date = .now) async throws -> ClaimStatus {
        guard var link = try store.load(), link.state == .pending, let requestID = link.requestID else { throw CloudError.notLinked }
        let key = try identityKey(link)
        let ts = Int64(now.timeIntervalSince1970)
        let signature = try key.signature(for: Data("vhc-link-claim-v1\n\(requestID)\n\(ts)".utf8))
        struct Body: Encodable { var timestamp: Int64; var signature: String }
        struct Reply: Decodable { var status: String; var installationId: String?; var accountPublicId: String? }
        let reply: Reply = try await call("POST", "/v1/link-requests/\(requestID)/claim",
                                          body: Body(timestamp: ts, signature: Base64URL.encode(signature)))
        guard let status = ClaimStatus(rawValue: reply.status) else { throw CloudError.malformed("the claim's status") }
        switch status {
        case .linked:
            guard let installation = reply.installationId, let account = reply.accountPublicId else {
                throw CloudError.malformed("the claim's answer")
            }
            link.state = .linked
            link.requestID = nil
            link.installationID = installation
            link.accountPublicID = account
            try store.save(link)
        case .denied, .expired:
            try store.delete()
        case .pending:
            break
        }
        return status
    }

    /// Unlinks this Mac: revokes the installation in the cloud (which also drops it as a holder and cancels its open
    /// requests and transfers), then forgets the identity key. A cloud that can't be reached leaves the key in place
    /// unless `force` (the owner can still revoke it in the portal).
    public func unlink(force: Bool = false) async throws {
        if let link = try store.load(), link.state == .linked {
            do {
                try await signedEmpty("DELETE", "/v1/installation")
            } catch CloudError.unauthenticated {
                // Already revoked.
            } catch {
                if !force { throw error }
            }
        }
        try store.delete()
    }

    // MARK: reads

    public func installation() async throws -> CloudInstallation { try await signed("GET", "/v1/installation") }

    /// Sends a problem report (`vh-report/1`, `POST /v1/reports`) signed as this Mac, once. `document` is the report
    /// exactly as the person read it; the answer is the service's receipt (`{"report": {id, reference, received_at}}`).
    public func sendReport(_ document: Data) async throws -> Data {
        try await signedData("POST", "/v1/reports", body: document)
    }

    public func deployments() async throws -> [CloudDeployment] {
        struct Reply: Decodable { var deployments: [CloudDeployment] }
        let reply: Reply = try await signed("GET", "/v1/deployments")
        return reply.deployments
    }

    public func vaults() async throws -> [CloudVault] {
        struct Reply: Decodable { var vaults: [CloudVault] }
        let reply: Reply = try await signed("GET", "/v1/vaults")
        return reply.vaults
    }

    /// The account key's chain, or nil before the account has one (404).
    public func accountKey() async throws -> CloudAccountKey? {
        do {
            return try await signed("GET", "/v1/keys/account")
        } catch CloudError.notFound {
            return nil
        }
    }

    public func unlocks() async throws -> CloudKeyUnlocks { try await signed("GET", "/v1/keys/account/unlocks") }

    public func holders() async throws -> [CloudKeyHolder] {
        struct Reply: Decodable { var holders: [CloudKeyHolder] }
        let reply: Reply = try await signed("GET", "/v1/keys/holders")
        return reply.holders
    }

    public func coverage() async throws -> [CloudRecoveryCoverage] {
        struct Reply: Decodable { var vaults: [CloudRecoveryCoverage] }
        let reply: Reply = try await signed("GET", "/v1/recovery/vaults")
        return reply.vaults
    }

    public func billing() async throws -> CloudBilling { try await signed("GET", "/v1/billing") }
    public func plans() async throws -> CloudPlans { try await signed("GET", "/v1/billing/plans") }

    // MARK: the account key: holders, requests, transfers

    /// Registers this Mac as a holder of the current generation.
    public func addHolder(suite: KeySuite, holderPublicKey: Data, generation: UInt32, proof: Data,
                          kak1: Data) async throws -> CloudKeyHolder {
        struct Body: Encodable { var suite: UInt16; var holderPublicKey: String; var generation: UInt32; var proof, kak1: String }
        return try await signed("POST", "/v1/keys/holders",
                                body: Body(suite: suite.rawValue, holderPublicKey: Base64URL.encode(holderPublicKey),
                                           generation: generation, proof: Base64URL.encode(proof), kak1: Base64URL.encode(kak1)))
    }

    /// Drops this Mac as a holder (it may drop only itself).
    public func removeHolder(installationID: String) async throws {
        try await signedEmpty("DELETE", "/v1/keys/holders/\(installationID)")
    }

    /// Asks the account holder to approve `action` in the portal. `payload` is the action's JSON document as text:
    /// both screens' request code hashes exactly these bytes.
    public func requestKeyChange(action: String, payload: String) async throws -> CloudKeyRequest {
        struct Body: Encodable { var action, payload: String }
        return try await signed("POST", "/v1/keys/requests", body: Body(action: action, payload: payload))
    }

    public func keyRequest(_ id: String) async throws -> CloudKeyRequest { try await signed("GET", "/v1/keys/requests/\(id)") }

    /// Asks a holder for the account key, sealed to `temporaryKey`.
    public func requestTransfer(suite: KeySuite, temporaryKey: Data) async throws -> CloudKeyTransfer {
        struct Body: Encodable { var suite: UInt16; var temporaryPublicKey: String }
        return try await signed("POST", "/v1/keys/transfers",
                                body: Body(suite: suite.rawValue, temporaryPublicKey: Base64URL.encode(temporaryKey)))
    }

    public func transfer(_ id: String) async throws -> CloudKeyTransfer { try await signed("GET", "/v1/keys/transfers/\(id)") }

    public func completeTransfer(_ id: String) async throws { try await signedEmpty("POST", "/v1/keys/transfers/\(id)/complete") }
    public func cancelTransfer(_ id: String) async throws { try await signedEmpty("POST", "/v1/keys/transfers/\(id)/cancel") }

    /// Transfers other devices asked for that this Mac, as a holder, may deliver.
    public func pendingTransfers() async throws -> [CloudKeyTransfer] {
        struct Reply: Decodable { var transfers: [CloudKeyTransfer] }
        let reply: Reply = try await signed("GET", "/v1/keys/transfers/pending")
        return reply.transfers
    }

    public func deliverTransfer(_ id: String, kak1: Data) async throws -> CloudKeyTransfer {
        struct Body: Encodable { var kak1: String }
        return try await signed("POST", "/v1/keys/transfers/\(id)/deliver", body: Body(kak1: Base64URL.encode(kak1)))
    }

    // MARK: billing

    /// A one-use link to the portal's checkout (`plan` optional) or billing portal; open it in the browser and poll
    /// ``billing()``.
    public func billingHandoff(kind: String, plan: String? = nil) async throws -> CloudBillingHandoff {
        struct Body: Encodable { var kind: String; var plan: String? }
        return try await signed("POST", "/v1/billing/handoffs", body: Body(kind: kind, plan: plan))
    }

    // MARK: restores (the delivering side)

    public struct Restore: Sendable, Equatable {
        public let id: String
        public let vaultUid: String
        public let requesterName: String
        public let requesterKind: String
        public let requesterFingerprint: String
        public let temporaryPublicKey: Data
        /// Computed here (vl-keykit) from the temporary key; the person compares it with the receiving server's.
        public let restoreCode: String
    }

    /// Restores of this account awaiting delivery (approved, requested by another installation).
    public func deliverable() async throws -> [Restore] {
        struct Reply: Decodable { var restores: [RestoreJSON] }
        let reply: Reply = try await signed("GET", "/v1/recovery/restores/deliverable")
        return try reply.restores.map { try $0.restore() }
    }

    public struct Delivered: Sendable, Equatable {
        public let versions: [UInt32]   // the key versions delivered
        public let missing: [UInt32]    // versions the cloud knows that this key didn't open
    }

    /// Delivers restore `id` with `key` (the account key, or a recovery kit's seed): opens the vault's stored
    /// envelopes with it and re-wraps each key version to the restore's temporary key, all inside vl-keykit. Call it
    /// only after the person confirmed that the receiving server shows `restore.restoreCode`.
    public func deliver(_ restore: Restore, key: AccountKey) async throws -> Delivered {
        struct Source: Decodable {
            struct Version: Decodable { var version: UInt32 }
            var envelopes: [String]?
            var keyVersions: [Version]?
        }
        let data = try await signedData("GET", "/v1/recovery/restores/\(restore.id)/source")
        let fresh = try Self.decoder.decode(RestoreJSON.self, from: data).restore()
        guard fresh.temporaryPublicKey == restore.temporaryPublicKey, fresh.vaultUid == restore.vaultUid else {
            throw CloudError.codeMismatch  // the key changed since the person compared the code
        }
        let source = try Self.decoder.decode(Source.self, from: data)
        guard let uid = Uid(base32: restore.vaultUid) else { throw CloudError.malformed("the vault uid") }
        var keys: [UInt32: VaultKey] = [:]
        for text in source.envelopes ?? [] {
            guard let env = Data(base64Encoded: text) else { continue }
            do {
                let opened = try key.openVaultKey(env, vaultUid: Data(uid.bytes))
                if keys[opened.keyVersion] == nil { keys[opened.keyVersion] = opened }
            } catch {
                // Another recipient's envelope (or one a restore passes over) is skipped; anything else too, but logged.
                if !KEV1Header.isSkippedByRestore(error) { Self.log.notice("restore: an envelope didn't open: \(error.name, privacy: .public)") }
            }
        }
        guard !keys.isEmpty else { throw CloudError.noEnvelopeOpens }
        var bundle: [String] = []
        for (_, vaultKey) in keys.sorted(by: { $0.key < $1.key }) {
            bundle.append(try vaultKey.wrap(suite: .x25519, to: restore.temporaryPublicKey).base64EncodedString())
        }
        struct Body: Encodable { var envelopes: [String] }
        _ = try await signedData("POST", "/v1/recovery/restores/\(restore.id)/bundle", body: encode(Body(envelopes: bundle)))
        let known = (source.keyVersions ?? []).map(\.version)
        return Delivered(versions: keys.keys.sorted(), missing: known.filter { keys[$0] == nil }.sorted())
    }

    /// Delivers restore `id` from a recovery kit (its seed is an account key's format): ``deliver(_:key:)``.
    public func deliver(_ restore: Restore, kit: RecoveryKit) async throws -> Delivered {
        let key: AccountKey
        do { key = try AccountKey(recoveryCode: kit.seed.text()) } catch { throw CloudError.malformed("the recovery kit's seed") }
        return try await deliver(restore, key: key)
    }

    // MARK: plumbing

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    func encode(_ body: some Encodable) throws -> Data { try Self.encoder.encode(body) }

    private func identityKey(_ link: CloudLink) throws -> Curve25519.Signing.PrivateKey {
        guard let raw = Data(base64Encoded: link.identityKey),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else { throw CloudError.malformed("the stored identity key") }
        return key
    }

    private func request(_ method: String, _ path: String, body: Data?) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        r.timeoutInterval = 30
        return r
    }

    private func call<R: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> R {
        let data = try await perform(request(method, path, body: try encode(body)))
        return try decode(data, path)
    }

    func signed<R: Decodable>(_ method: String, _ path: String) async throws -> R {
        try decode(try await signedData(method, path), path)
    }

    func signed<R: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> R {
        try decode(try await signedData(method, path, body: try encode(body)), path)
    }

    func signedEmpty(_ method: String, _ path: String) async throws {
        _ = try await signedData(method, path)
    }

    func signedData(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        guard let link = try store.load(), link.state == .linked, let installation = link.installationID else {
            throw CloudError.notLinked
        }
        var r = request(method, path, body: body)
        let q = path.firstIndex(of: "?")
        let fields = VHC1.Fields(method: method, path: q.map { String(path[..<$0]) } ?? path,
                                 query: q.map { String(path[path.index(after: $0)...]) } ?? "", host: host,
                                 installation: installation, timestamp: Int64(Date.now.timeIntervalSince1970),
                                 nonce: VHC1.newNonce(), bodySHA256: VHC1.sha256Hex(body ?? Data()))
        for (k, v) in try VHC1.headers(fields, key: identityKey(link)) { r.setValue(v, forHTTPHeaderField: k) }
        return try await perform(r)
    }

    private func decode<R: Decodable>(_ data: Data, _ path: String) throws -> R {
        do {
            return try Self.decoder.decode(R.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            Self.log.error("cloud: undecodable answer from \(path, privacy: .public)")
            throw CloudError.malformed(path)
        }
    }

    private func perform(_ r: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(r)
        } catch let error as CloudError {
            throw error
        } catch {
            throw CloudError.unreachable(String(describing: error))
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            let error = CloudError.from(status: response.statusCode, body: data,
                                        retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            Self.log.notice("cloud: \(r.httpMethod ?? "", privacy: .public) \(r.url?.path ?? "", privacy: .public) refused \(response.statusCode)")
            throw error
        }
        return data
    }
}

/// A restore as the daemon serves it.
struct RestoreJSON: Decodable {
    struct Requester: Decodable {
        var installationId: String?
        var name: String?
        var kind: String?
        var fingerprint: String?
    }

    var id: String
    var vaultUid: String
    var temporaryPublicKey: String
    var requester: Requester?
    var restoreCode: String?

    func restore() throws -> CloudClient.Restore {
        guard let pk = Data(base64Encoded: temporaryPublicKey), pk.count == 32 else { throw CloudError.malformed("a restore") }
        let code = try KeyCodes.restore(vaultUid: vaultUid, temporaryKey: pk)
        if let claimed = restoreCode, claimed != code { throw CloudError.codeMismatch }
        return CloudClient.Restore(id: id, vaultUid: vaultUid, requesterName: requester?.name ?? "?",
                                   requesterKind: requester?.kind ?? "?",
                                   requesterFingerprint: requester?.fingerprint ?? "?", temporaryPublicKey: pk,
                                   restoreCode: code)
    }
}

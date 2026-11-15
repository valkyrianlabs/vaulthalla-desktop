public import Foundation
public import VHCore
public import VHKeykit
import OSLog
import VHRecovery

/// The account recovery key on this Mac (docs/cloud-storage.md, "The account recovery key on this Mac"; the cloud's
/// key-manager.md): receiving it (a transfer from another holder, or the recovery code typed in), keeping it as KAK1
/// sealed to this Mac's holder key, unlocking it for one operation at a time, delivering transfers and restores, and
/// the key requests that change it (create, rotate, offline copy), which the account holder approves in the portal.
///
/// Every key format and construction is vl-keykit's (VHKeykit). The seed exists only inside a VLKeykit handle during
/// one operation; the recovery code leaves one only when the person is shown it.
public actor CloudAccount {
    public nonisolated let client: CloudClient
    public nonisolated let keys: AccountKeyStore
    let holderKeys: HolderKeys
    let items: LeasedAccountItems
    /// What the Touch ID prompt says when the holder key is used.
    public var unlockReason = "unlock your Vaulthalla Cloud recovery key"

    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "cloud-key")
    static let transferItem = "account-key.transfer"

    public init(client: CloudClient, items: LeasedAccountItems, holderKeys: HolderKeys = HolderKeys()) {
        self.client = client
        self.items = items
        keys = AccountKeyStore(items: items)
        self.holderKeys = holderKeys
    }

    // MARK: - status

    /// The account key as the cloud serves it, checked here, and as this Mac holds it.
    public struct KeyStatus: Sendable, Equatable {
        /// nil: the account has no recovery key yet.
        public var cloud: CloudAccountKey?
        /// The chain as verified here (every signature, for this account).
        public var chain: [VerifiedGeneration]
        /// The current generation's statement, verified.
        public var current: KeyStatement?
        public var held: HeldAccountKey?
        public var pending: HeldAccountKey?
        /// A transfer this Mac asked for and waits on.
        public var transfer: PendingTransfer?

        /// This Mac holds the current generation.
        public var holdsCurrent: Bool {
            guard let held, let current else { return false }
            return held.statement == current && held.registered
        }

        /// The fingerprint to show: the one this Mac computes from the key it holds, never the cloud's.
        public var fingerprint: Fingerprint? { held?.fingerprint }

        public var offlineCopyConfirmedAt: Date? {
            cloud?.offlineCopyConfirmedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }

        /// The current generation is newer than the one held and wasn't signed by it (a replacement): a warning with
        /// the new fingerprint, never followed on its own.
        public var unsignedReplacement: Fingerprint? {
            guard let held, let current, current.generation > held.generation,
                  let link = chain.last?.link, link == .replacement else { return nil }
            return current.fingerprint
        }
    }

    public struct PendingTransfer: Codable, Sendable, Equatable {
        public var id: String
        /// The code this Mac computes from its temporary key; the delivering holder must show the same.
        public var code: String
        public var holderKind: HolderKeyKind
        public var holderKey: Data
        public var holderPublicKey: Data
        public var expiresAt: Int64
    }

    /// Reads the key's state, checks the chain and follows a signed rotation this Mac was resealed for.
    public func status() async throws -> KeyStatus {
        let publicID = try accountPublicID()
        let cloud = try await client.accountKey()
        var status = KeyStatus(cloud: cloud, chain: [], current: nil, held: try keys.held(), pending: try keys.pending(),
                               transfer: try pendingTransfer())
        guard let cloud else { return status }
        let (chain, current) = try verify(cloud, publicID: publicID)
        status.chain = chain
        status.current = current
        if let held = status.held, held.generation < current.generation, held.registered {
            status.held = try await followRotation(from: held, chain: cloud, publicID: publicID) ?? held
        }
        return status
    }

    /// Verifies the cloud's chain for this account and returns it with the current statement.
    func verify(_ cloud: CloudAccountKey, publicID: String) throws -> ([VerifiedGeneration], KeyStatement) {
        guard cloud.publicId == publicID else { throw CloudError.keyMismatch("The recovery key is for another account.") }
        let signed = try signedChain(cloud)
        let chain: [VerifiedGeneration]
        do {
            chain = try KeyChain.verify(signed, publicID: publicID)
        } catch {
            throw CloudError.keyMismatch("Vaulthalla Cloud's recovery key doesn't verify (\(error.name)).")
        }
        guard let last = cloud.chain.last, last.generation == cloud.current.generation, let current = try? KeyStatement(last.statement)
        else { throw CloudError.malformed("the current key generation") }
        return (chain, current)
    }

    private func signedChain(_ cloud: CloudAccountKey) throws -> [SignedStatement] {
        try cloud.chain.map { g in
            guard let sig = Base64URL.decode(g.signature) else { throw CloudError.malformed("a key signature") }
            let prev = try g.previousSignature.map { text in
                guard let d = Base64URL.decode(text) else { throw CloudError.malformed("a key signature") }
                return d
            }
            return SignedStatement(statement: g.statement, signature: sig, previousSignature: prev)
        }
    }

    /// A rotation resealed this Mac's holder row: take the new generation's KAK1 when the chain reaches it from the
    /// held generation through signed rotations only, and the KAK1 opens to that generation's key.
    private func followRotation(from held: HeldAccountKey, chain cloud: CloudAccountKey,
                                publicID: String) async throws -> HeldAccountKey? {
        let (accepted, _) = try KeyChain.follow(try signedChain(cloud), publicID: publicID, pinGeneration: held.generation,
                                                pinFingerprint: held.fingerprint)
        let installation = try installationID()
        guard let mine = try await client.holders().first(where: { $0.installationId == installation }),
              mine.generation <= accepted, mine.generation > held.generation,
              let kak1 = mine.kak1.flatMap(Base64URL.decode),
              let entry = cloud.chain.first(where: { $0.generation == mine.generation }),
              let statement = try? KeyStatement(entry.statement)
        else { return nil }
        // The cloud checked the KAK1's prefix only; its prefix must name this generation and this holder key.
        let header = try KAK1Header(kak1)
        guard header.generation == statement.generation, header.fingerprint == statement.fingerprint.bytes,
              header.recipientID == (try Keykit.recipientID(of: held.holderPublicKey))
        else { return nil }
        var next = held
        next.statement = statement
        next.kak1 = kak1
        next.storedAt = .now
        try keys.saveHeld(next)
        Self.log.info("followed a signed rotation to generation \(statement.generation)")
        return next
    }

    // MARK: - using the key

    /// Unlocks the held key for `body` (Touch ID or the password where the holder key is in the Secure Enclave).
    public func withAccountKey<R: Sendable>(_ body: (AccountKey, KeyStatement) throws -> R) throws -> R {
        guard let held = try keys.held() else { throw CloudError.keyMismatch("This Mac doesn't hold the recovery key.") }
        let holder = try holderKeys.open(kind: held.holderKind, stored: held.holderKey, reason: unlockReason)
        let key = try AccountKey.unwrap(held.kak1, holder: holder, statement: held.statement)
        guard key.matches(held.statement) else { throw CloudError.keyMismatch("The stored recovery key doesn't open.") }
        return try body(key, held.statement)
    }

    /// The recovery code of the held key, to show, print or save: one unlock.
    public func exportRecoveryCode() throws -> SecretBytes {
        try withAccountKey { key, _ in try key.recoveryCode() }
    }

    /// Opens the vaults' sealed names with the held key (one unlock for all). A label sealed to another generation
    /// stays closed.
    public func openLabels(_ vaults: [CloudVault]) throws -> [String: String] {
        let sealed = vaults.compactMap { v -> (String, Data, Data)? in
            guard let label = v.label.flatMap(Base64URL.decode), let uid = Uid32.bytes(v.vaultUid) else { return nil }
            return (v.vaultUid, label, uid)
        }
        guard !sealed.isEmpty else { return [:] }
        return try withAccountKey { key, statement in
            var out: [String: String] = [:]
            for (uid, label, bytes) in sealed {
                if let name = try? key.openLabel(label, statement: statement, vaultUid: bytes) { out[uid] = name }
            }
            return out
        }
    }

    /// Delivers a restore with the account key. Call it only after the person confirmed the restore code.
    public func deliver(_ restore: CloudClient.Restore) async throws -> CloudClient.Delivered {
        guard let held = try keys.held() else { throw CloudError.keyMismatch("This Mac doesn't hold the recovery key.") }
        let holder = try holderKeys.open(kind: held.holderKind, stored: held.holderKey, reason: unlockReason)
        let key = try AccountKey.unwrap(held.kak1, holder: holder, statement: held.statement)
        return try await client.deliver(restore, key: key)
    }

    /// A transfer another device asked for, with the code this Mac computes from its temporary key.
    public struct DeliverableTransfer: Sendable, Equatable, Identifiable {
        public let transfer: CloudKeyTransfer
        public let code: String
        public var id: String { transfer.id }
    }

    /// Transfers this Mac may deliver as a holder. One whose cloud code differs from the computed one is dropped.
    public func deliverableTransfers() async throws -> [DeliverableTransfer] {
        let publicID = try accountPublicID()
        guard try keys.held()?.registered == true else { return [] }
        return try await client.pendingTransfers().compactMap { t in
            guard let key = Base64URL.decode(t.temporaryPublicKey),
                  let code = try? KeyCodes.transfer(publicID: publicID, temporaryKey: key), code == t.transferCode
            else { return nil }
            return DeliverableTransfer(transfer: t, code: code)
        }
    }

    /// Seals the account key to a transfer's temporary key and delivers it. Call it only after the person confirmed
    /// that the new device shows `transfer.code`.
    public func deliver(_ transfer: DeliverableTransfer) async throws {
        guard let suite = KeySuite(rawValue: transfer.transfer.suite),
              let temporary = Base64URL.decode(transfer.transfer.temporaryPublicKey)
        else { throw CloudError.malformed("the transfer") }
        guard try KeyCodes.transfer(publicID: try accountPublicID(), temporaryKey: temporary) == transfer.code else {
            throw CloudError.codeMismatch
        }
        let kak1 = try withAccountKey { key, statement in try key.wrap(statement, suite: suite, to: temporary) }
        _ = try await client.deliverTransfer(transfer.transfer.id, kak1: kak1)
    }

    // MARK: - receiving the key

    /// The recovery code typed in: no route takes it. Desktop derives the key, checks it is the current generation's,
    /// seals it to a new holder key and registers as a holder.
    public func receive(recoveryCode: SecretBytes) async throws -> Fingerprint {
        let publicID = try accountPublicID()
        guard let cloud = try await client.accountKey() else {
            throw CloudError.keyMismatch("Your account has no recovery key yet.")
        }
        let (_, current) = try verify(cloud, publicID: publicID)
        let key: AccountKey
        do {
            key = try AccountKey(recoveryCode: recoveryCode)
        } catch {
            throw CloudError.keyMismatch("That isn't a recovery code: check it and try again.")
        }
        guard key.matches(current) else {
            let older = cloud.chain.contains { (try? KeyStatement($0.statement)).map(key.matches) ?? false }
            throw CloudError.keyMismatch(older ? "That recovery code is for an earlier recovery key, which was replaced."
                                               : "That recovery code isn't your account's recovery key.")
        }
        return try await hold(key, statement: current, holder: try holderKeys.create())
    }

    /// Asks for the key from another holder. The temporary key is this Mac's new holder key itself, so the KAK1 a
    /// holder delivers is kept as it is (decision: one key, no re-wrap).
    public func requestTransfer() async throws -> PendingTransfer {
        let publicID = try accountPublicID()
        let holder = try holderKeys.create()
        let t = try await client.requestTransfer(suite: .p256, temporaryKey: holder.publicKey)
        let code = try KeyCodes.transfer(publicID: publicID, temporaryKey: holder.publicKey)
        guard code == t.transferCode, Base64URL.decode(t.temporaryPublicKey) == holder.publicKey else {
            try? await client.cancelTransfer(t.id)
            throw CloudError.codeMismatch
        }
        let pending = PendingTransfer(id: t.id, code: code, holderKind: holder.kind, holderKey: holder.storedRepresentation,
                                      holderPublicKey: holder.publicKey, expiresAt: t.expiresAt)
        try items.write(Self.transferItem, JSONEncoder().encode(pending), operation: "ask for the recovery key")
        return pending
    }

    public enum TransferOutcome: Sendable, Equatable {
        case waiting
        case received(Fingerprint)
        /// cancelled or expired: ask again.
        case closed(String)
    }

    /// Checks the transfer this Mac waits on; once delivered, opens it, registers as a holder and completes it.
    public func checkTransfer() async throws -> TransferOutcome {
        guard let pending = try pendingTransfer() else { return .closed("none") }
        let t = try await client.transfer(pending.id)
        switch t.status {
        case "requested": return .waiting
        case "delivered":
            guard let kak1 = t.kak1.flatMap(Base64URL.decode) else { throw CloudError.malformed("the delivered key") }
            guard let cloud = try await client.accountKey() else { throw CloudError.malformed("the account key") }
            let (_, current) = try verify(cloud, publicID: try accountPublicID())
            let holder = try holderKeys.open(kind: pending.holderKind, stored: pending.holderKey, reason: unlockReason)
            let key = try AccountKey.unwrap(kak1, holder: holder, statement: current)
            let fingerprint = try await hold(key, statement: current, holder: holder, kak1: kak1)
            try? await client.completeTransfer(pending.id)
            try? items.delete(Self.transferItem, operation: "ask for the recovery key")
            return .received(fingerprint)
        default:
            try? items.delete(Self.transferItem, operation: "ask for the recovery key")
            return .closed(t.status)
        }
    }

    public func cancelTransfer() async throws {
        guard let pending = try pendingTransfer() else { return }
        try? await client.cancelTransfer(pending.id)
        try items.delete(Self.transferItem, operation: "ask for the recovery key")
    }

    func pendingTransfer() throws -> PendingTransfer? {
        guard let data = try items.read(Self.transferItem) else { return nil }
        return try? JSONDecoder().decode(PendingTransfer.self, from: data)
    }

    /// Seals `key` to `holder` (or keeps `kak1` already sealed to it), registers as a holder and stores it.
    private func hold(_ key: AccountKey, statement: KeyStatement, holder: any HolderKey,
                      kak1 sealed: Data? = nil) async throws -> Fingerprint {
        let kak1 = try sealed ?? key.wrap(statement, suite: .p256, to: holder.publicKey)
        let proof = try key.holderProof(statement, installationID: try installationID(), suite: .p256,
                                        holderPublicKey: holder.publicKey)
        _ = try await client.addHolder(suite: .p256, holderPublicKey: holder.publicKey, generation: statement.generation,
                                       proof: proof, kak1: kak1)
        try keys.saveHeld(HeldAccountKey(accountPublicID: try accountPublicID(), statement: statement, holderKind: holder.kind,
                                         holderKey: holder.storedRepresentation, holderPublicKey: holder.publicKey,
                                         kak1: kak1, registered: true))
        return statement.fingerprint
    }

    // MARK: - changing the key: requests approved in the portal

    /// A new account key, before it is sent anywhere: the person is shown its recovery code and confirms an offline
    /// copy first.
    public final class NewKey: @unchecked Sendable {
        public let key: AccountKey
        public let statement: KeyStatement
        let previous: AccountKey?
        init(key: AccountKey, statement: KeyStatement, previous: AccountKey?) {
            self.key = key
            self.statement = statement
            self.previous = previous
        }

        public func recoveryCode() throws -> SecretBytes { try key.recoveryCode() }
    }

    /// A key request waiting in the portal, with the code Desktop computed from its id and payload.
    public struct OpenRequest: Sendable, Equatable {
        public let request: CloudKeyRequest
        public let code: String
    }

    /// Generation 1 for an account without a key (onboarding).
    public func prepareFirstKey() throws -> NewKey {
        let key = try AccountKey.generate()
        let statement = try key.statement(publicID: try accountPublicID(), generation: 1, previous: nil, reason: .initial)
        return NewKey(key: key, statement: statement, previous: nil)
    }

    /// The next generation, signed by the held one: a routine rotation, or `compromise` (servers then rotate vault
    /// keys too).
    public func prepareRotation(reason: KeyReason = .routine) throws -> NewKey {
        guard let held = try keys.held(), held.registered else {
            throw CloudError.keyMismatch("This Mac doesn't hold the recovery key.")
        }
        let holder = try holderKeys.open(kind: held.holderKind, stored: held.holderKey, reason: unlockReason)
        let previous = try AccountKey.unwrap(held.kak1, holder: holder, statement: held.statement)
        let key = try AccountKey.generate()
        let statement = try key.statement(publicID: held.accountPublicID, generation: held.generation + 1,
                                          previous: held.fingerprint, reason: reason)
        return NewKey(key: key, statement: statement, previous: previous)
    }

    /// Sends a prepared key as a `create` or `rotate` request (offline copy confirmed: the person saved the code), and
    /// keeps it, sealed to this Mac's holder key, until the request is decided.
    public func submit(_ new: NewKey, offlineCopyConfirmed: Bool) async throws -> OpenRequest {
        let signed = try new.key.sign(new.statement, previous: new.previous)
        let held = try keys.held()
        let holder: any HolderKey = try held.map {
            try holderKeys.open(kind: $0.holderKind, stored: $0.holderKey, reason: nil)
        } ?? holderKeys.create()
        let kak1 = try new.key.wrap(new.statement, suite: .p256, to: holder.publicKey)
        var payload = GenerationPayload(statement: signed.statement, signature: Base64URL.encode(signed.signature),
                                        previousSignature: signed.previousSignature.map { Base64URL.encode($0) },
                                        offlineCopyConfirmed: offlineCopyConfirmed, holders: nil)
        let action = new.previous == nil ? "create" : "rotate"
        if new.previous != nil {
            // Every holder is resealed for the new generation, this Mac with the KAK1 it keeps; the rest are dropped.
            let installation = try installationID()
            payload.holders = try await client.holders().compactMap { h in
                guard let suite = KeySuite(rawValue: h.suite), let pk = Base64URL.decode(h.holderPublicKey) else { return nil }
                let sealed = h.installationId == installation && pk == holder.publicKey ? kak1
                    : try new.key.wrap(new.statement, suite: suite, to: pk)
                let proof = try new.key.holderProof(new.statement, installationID: h.installationId, suite: suite,
                                                    holderPublicKey: pk)
                return .init(installationId: h.installationId, proof: Base64URL.encode(proof), kak1: Base64URL.encode(sealed))
            }
        }
        let text = String(decoding: try CloudClient.encoder.encode(payload), as: UTF8.self)
        let request = try await client.requestKeyChange(action: action, payload: text)
        let code = try KeyCodes.request(id: request.id, payload: text)
        guard code == request.requestCode else { throw CloudError.codeMismatch }
        try keys.savePending(HeldAccountKey(accountPublicID: try accountPublicID(), statement: new.statement,
                                            holderKind: holder.kind, holderKey: holder.storedRepresentation,
                                            holderPublicKey: holder.publicKey, kak1: kak1,
                                            registered: action == "rotate" && (held?.registered ?? false),
                                            pendingRequestID: request.id, pendingPayload: text))
        return OpenRequest(request: request, code: code)
    }

    /// Records an offline copy (a kit exported, or the code printed) made after the key was created.
    public func requestOfflineCopy() async throws -> OpenRequest {
        guard let held = try keys.held() else { throw CloudError.keyMismatch("This Mac doesn't hold the recovery key.") }
        struct Payload: Encodable { var generation: UInt32; var fingerprint: String }
        let text = String(decoding: try CloudClient.encoder.encode(Payload(generation: held.generation,
                                                                            fingerprint: held.fingerprint.text)), as: UTF8.self)
        let request = try await client.requestKeyChange(action: "offline_copy", payload: text)
        let code = try KeyCodes.request(id: request.id, payload: text)
        guard code == request.requestCode else { throw CloudError.codeMismatch }
        return OpenRequest(request: request, code: code)
    }

    public enum RequestOutcome: Sendable, Equatable {
        case waiting(code: String)
        case applied
        case closed(String)
    }

    /// Checks the pending key's request: approved, the new generation becomes the held one (and, for the first key,
    /// this Mac registers as its holder); denied or expired, it is forgotten.
    public func checkPendingKey() async throws -> RequestOutcome? {
        guard let pending = try keys.pending(), let id = pending.pendingRequestID, let payload = pending.pendingPayload
        else { return nil }
        let request = try await client.keyRequest(id)
        switch request.status {
        case "requested":
            return .waiting(code: try KeyCodes.request(id: id, payload: payload))
        case "approved":
            if !pending.registered {
                let holder = try holderKeys.open(kind: pending.holderKind, stored: pending.holderKey, reason: unlockReason)
                let key = try AccountKey.unwrap(pending.kak1, holder: holder, statement: pending.statement)
                let proof = try key.holderProof(pending.statement, installationID: try installationID(), suite: .p256,
                                                holderPublicKey: pending.holderPublicKey)
                _ = try await client.addHolder(suite: .p256, holderPublicKey: pending.holderPublicKey,
                                               generation: pending.generation, proof: proof, kak1: pending.kak1)
                var registered = pending
                registered.registered = true
                try keys.savePending(registered)
            }
            try keys.promotePending()
            return .applied
        default:
            try keys.deletePending()
            return .closed(request.status)
        }
    }

    /// A request's state, by id (an offline-copy request is not kept locally).
    public func check(request id: String) async throws -> CloudKeyRequest { try await client.keyRequest(id) }

    // MARK: - plumbing

    func accountPublicID() throws -> String {
        guard let link = try client.link(), link.state == .linked, let id = link.accountPublicID else { throw CloudError.notLinked }
        return id
    }

    func installationID() throws -> String {
        guard let link = try client.link(), link.state == .linked, let id = link.installationID else { throw CloudError.notLinked }
        return id
    }
}

/// A key request's generation document (`create`, `rotate`), sent as text.
struct GenerationPayload: Encodable {
    struct Holder: Encodable {
        var installationId: String
        var proof: String
        var kak1: String
    }

    var statement: String
    var signature: String
    var previousSignature: String?
    var offlineCopyConfirmed: Bool
    var holders: [Holder]?
}

/// A vault uid's 16 bytes from its text (VHRecovery's strict base32).
enum Uid32 {
    static func bytes(_ text: String) -> Data? { Uid(base32: text).map { Data($0.bytes) } }
}

import Foundation
import VHContract

/// What the New Vault sheet holds while the person fills it in, and the `storage.vault.add` payload it becomes
/// (built member by member; the web console's NewVaultPage is the reference).
struct NewVaultDraft {
    typealias Payload = Ws.Storage.Vault.Add.Payload
    typealias Strategy = Payload.Sync.Strategy
    typealias Conflict = Payload.Sync.ConflictPolicy
    typealias BucketMode = Payload.Provision.Mode

    enum QuotaUnit: String, CaseIterable, Identifiable {
        case mib = "MiB", gib = "GiB", tib = "TiB"
        var id: Self { self }
        var bytes: Double {
            switch self {
            case .mib: 1_048_576
            case .gib: 1_073_741_824
            case .tib: 1_099_511_627_776
            }
        }
    }

    enum GuardrailPreset: String, CaseIterable, Identifiable {
        case conservative, balanced, bulk, unlimited
        var id: Self { self }
    }

    var type: Payload.TypeValue = .local
    var name = ""
    var summary = ""
    var quotaAmount = ""
    var quotaUnit = QuotaUnit.gib
    /// nil: the daemon's default (the account this Mac acts for).
    var ownerID: Int64?
    var slug = ""
    var fuseName = ""

    // S3
    var apiKeyID: Int64?
    var bucketMode = BucketMode.existing
    var bucket = ""
    var generateName = false
    var region = ""
    var abortMultipartDays = "7"
    var events = false
    var eventsPrefix = ""
    var storageTier = ""
    var encryptUpstream = true

    // Sync. Strategy and conflict policy start from the node's vaults.s3.* defaults unless the person chose.
    var syncEnabled = true
    var strategy = Strategy.cache
    var conflict = Conflict.ask
    var strategyChosen = false
    var conflictChosen = false
    var intervalSeconds: Int64 = 300
    var maxIndexAge = "86400"
    var guardrails = GuardrailPreset.balanced

    var isS3: Bool { type == .s3 }

    // MARK: Validation

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBucket: String { bucket.trimmingCharacters(in: .whitespacesAndNewlines) }

    var quotaBytes: Int64? {
        let text = quotaAmount.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 0 }
        guard let amount = Double(text), amount >= 0, amount.isFinite else { return nil }
        return Int64((amount * quotaUnit.bytes).rounded())
    }

    var slugProblem: String? {
        let text = slug.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return text.wholeMatch(of: /[a-z0-9][a-z0-9-]{1,61}[a-z0-9]/) == nil
            ? "Use 3–63 lowercase letters, digits or hyphens." : nil
    }

    var fuseProblem: String? {
        let text = fuseName.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text == "." || text == ".." || text.contains(/[\/\\\u{0}]/) {
            return "Use a single folder name: no slashes, not . or .."
        }
        return nil
    }

    var bucketProblem: String? {
        guard isS3 else { return nil }
        switch bucketMode {
        case .existing:
            return trimmedBucket.isEmpty ? "Enter the bucket name." : nil
        case .create:
            if generateName { return nil }
            return trimmedBucket.wholeMatch(of: /(?!xn--)(?!.*-s3alias$)[a-z0-9][a-z0-9-]{1,61}[a-z0-9]/) == nil
                ? "Use 3–63 lowercase letters, digits or hyphens." : nil
        case .adopt:
            return trimmedBucket.isEmpty ? "Choose a bucket." : nil
        }
    }

    var abortDays: Int64?? {
        let text = abortMultipartDays.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .some(nil) }
        guard let days = Int64(text), days >= 0, days <= 36_500 else { return nil }
        return .some(days)
    }

    var indexAge: Int64?? {
        let text = maxIndexAge.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .some(nil) }
        guard let seconds = Int64(text), seconds >= 0 else { return nil }
        return .some(seconds)
    }

    var isValid: Bool {
        guard !trimmedName.isEmpty, quotaBytes != nil, slugProblem == nil, fuseProblem == nil else { return false }
        guard isS3 else { return true }
        return apiKeyID != nil && bucketProblem == nil && (bucketMode != .create || abortDays != nil) && indexAge != nil
    }

    // MARK: Payload

    /// `canProvision`: the chosen credential has provider administration, so `bucketMode` applies; otherwise the
    /// bucket is bound by name.
    func payload(canProvision: Bool) -> Payload {
        var payload = Payload(name: trimmedName, type: type)
        let description = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { payload.description = description }
        if let quota = quotaBytes, quota > 0 { payload.quota = quota }
        if let ownerID { payload.ownerID = .value(ownerID) }
        let slug = slug.trimmingCharacters(in: .whitespaces)
        if !slug.isEmpty { payload.slug = slug }
        let fuse = fuseName.trimmingCharacters(in: .whitespaces)
        if !fuse.isEmpty { payload.fuseName = .value(fuse) }
        guard isS3 else { return payload }

        let mode = canProvision ? bucketMode : .existing
        payload.apiKeyID = apiKeyID
        payload.bucket = mode == .create && generateName ? "" : trimmedBucket
        if !storageTier.isEmpty { payload.storageTierID = .value(storageTier) }
        payload.encryptUpstream = encryptUpstream
        payload.sync = Payload.Sync(
            interval: .integer(max(1, intervalSeconds)), enabled: syncEnabled, strategy: strategy,
            conflictPolicy: conflict, maxRemoteIndexAgeSeconds: (indexAge ?? nil).map { .value($0) } ?? .null,
            s3RequestBudget: Self.budget(guardrails))
        if mode != .existing { payload.provision = .value(provision(mode)) }
        return payload
    }

    /// The `provision` member for creating or adopting a bucket. Adoption itself is accepted only through the
    /// daemon's `upstream_adoption` confirmation.
    private func provision(_ mode: BucketMode) -> Payload.Provision {
        var provision = Payload.Provision(mode: .value(mode))
        if events {
            provision.events = .value(true)
            let prefix = eventsPrefix.trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty { provision.eventsPrefix = .value(prefix) }
        }
        guard mode == .create else { return provision }
        if generateName { provision.generateName = .value(true) }
        let region = region.trimmingCharacters(in: .whitespaces)
        if !region.isEmpty { provision.region = .value(region) }
        if let days = abortDays ?? nil, days > 0 {
            provision.lifecycle = .value(.init(abortIncompleteMultipartDays: .value(days)))
        }
        return provision
    }

    // MARK: Options

    static func budget(_ preset: GuardrailPreset) -> Payload.Sync.S3RequestBudget {
        let gib: Int64 = 1_073_741_824
        func make(_ list: Int64, _ head: Int64, _ get: Int64, _ put: Int64, _ copy: Int64, _ delete: Int64,
                  _ bytes: Int64) -> Payload.Sync.S3RequestBudget {
            .init(listRequests: .value(list), headRequests: .value(head), getRequests: .value(get),
                  putRequests: .value(put), copyRequests: .value(copy), deleteRequests: .value(delete),
                  downloadedBytes: .value(bytes))
        }
        switch preset {
        case .conservative: return make(10, 100, 100, 100, 20, 100, gib)
        case .balanced: return make(100, 1000, 1000, 1000, 100, 1000, 10 * gib)
        case .bulk: return make(1000, 10_000, 10_000, 10_000, 1000, 10_000, 100 * gib)
        case .unlimited:
            return .init(listRequests: .null, headRequests: .null, getRequests: .null, putRequests: .null,
                         copyRequests: .null, deleteRequests: .null, downloadedBytes: .null)
        }
    }

    static func presetTitle(_ preset: GuardrailPreset) -> String {
        switch preset {
        case .conservative: "Conservative"
        case .balanced: "Balanced"
        case .bulk: "Bulk"
        case .unlimited: "Unlimited"
        }
    }

    static func presetHint(_ preset: GuardrailPreset) -> String {
        switch preset {
        case .conservative: "Small, cheap runs: 10 LIST, 100 GET/PUT/HEAD/DELETE, 20 COPY and 1 GiB downloaded per run."
        case .balanced: "The default: 100 LIST, 1,000 GET/PUT/HEAD/DELETE, 100 COPY and 10 GiB downloaded per run."
        case .bulk: "Large migrations: 1,000 LIST, 10,000 GET/PUT/HEAD/DELETE, 1,000 COPY and 100 GiB per run."
        case .unlimited: "No per-run request limits. Price budgets still apply."
        }
    }

    static func strategyTitle(_ strategy: Strategy) -> String {
        switch strategy {
        case .cache: "Cache"
        case .sync: "Sync"
        case .mirror: "Mirror"
        }
    }

    static func strategyHint(_ strategy: Strategy) -> String {
        switch strategy {
        case .cache: "Fetch from the bucket on demand and keep a local cache."
        case .sync: "Two-way: keep the vault and the bucket in step."
        case .mirror: "One-way: make the bucket match the vault."
        }
    }

    /// The conflict policies an S3 vault takes.
    static let s3Conflicts: [Conflict] = [.keepLocal, .keepRemote, .keepNewest, .ask]

    static func conflictTitle(_ conflict: Conflict) -> String {
        switch conflict {
        case .keepLocal: "Keep local"
        case .keepRemote: "Keep remote"
        case .keepNewest: "Keep newest"
        case .ask: "Ask"
        case .overwrite: "Overwrite"
        case .keepBoth: "Keep both"
        }
    }

    static func conflictHint(_ conflict: Conflict) -> String {
        switch conflict {
        case .keepLocal: "The vault's copy wins: it is uploaded over the bucket's."
        case .keepRemote: "The bucket's copy wins: it is downloaded over the vault's."
        case .keepNewest: "The most recently modified copy wins."
        case .ask: "Records a sync conflict and waits for a decision in Sync Conflicts; everything else keeps syncing."
        case .overwrite, .keepBoth: ""
        }
    }

    static let intervals: [(seconds: Int64, title: String)] = [
        (60, "Every minute"), (300, "Every 5 minutes"), (600, "Every 10 minutes"), (900, "Every 15 minutes"),
        (1800, "Every 30 minutes"), (3600, "Every hour"), (21_600, "Every 6 hours"), (86_400, "Every day"),
    ]

    /// Storage classes the daemon knows per provider; others use the provider default.
    static func storageTiers(provider: String?) -> [(id: String, title: String)]? {
        switch provider {
        case WsModel.APIKey.Provider.aws:
            [("", "Provider default"), ("standard", "Standard"), ("standard_ia", "Standard-IA")]
        case WsModel.APIKey.Provider.cloudflareR2:
            [("", "Provider default"), ("standard", "Standard"), ("infrequent_access", "Infrequent Access")]
        default: nil
        }
    }
}

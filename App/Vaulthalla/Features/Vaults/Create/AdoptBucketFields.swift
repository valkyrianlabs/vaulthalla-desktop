import SwiftUI
import VHContract
import VHNodes

/// Adopting an existing bucket into a new vault: pick one of the account's unmanaged, unprotected buckets no vault
/// uses (`upstream.bucket.list`), then check it (`upstream.bucket.adopt.preflight`, read-only) to see what is in it.
/// The adoption itself is the daemon's question (`upstream_adoption`), asked when the vault is created.
struct AdoptBucketFields: View {
    var queries: NodeQueries
    var apiKeyID: Int64
    @Binding var draft: NewVaultDraft

    @State private var check: NodeMutation<Ws.Upstream.Bucket.Adopt.Preflight>
    @State private var report: (bucket: String, report: WsModel.UpstreamAdmissionReport)?

    init(queries: NodeQueries, apiKeyID: Int64, draft: Binding<NewVaultDraft>) {
        self.queries = queries
        self.apiKeyID = apiKeyID
        _draft = draft
        _check = State(initialValue: NodeMutation(Ws.Upstream.Bucket.Adopt.Preflight.self, on: queries))
    }

    var body: some View {
        let inventory = queries.query(Ws.Upstream.Bucket.List.self,
                                      .init(apiKeyID: apiKeyID, max: .value(1000), state: .value(.unmanaged)))
        Group {
            switch inventory.state {
            case .idle, .loading:
                LabeledContent("Existing bucket") { ProgressView().controlSize(.small) }
            case .failed(let error):
                LabeledContent("Existing bucket") { InlineProblem(error: error, subject: "this account's buckets") }
            case .loaded(let value, _):
                let buckets = value.inventory.buckets.filter { !$0.isProtected && $0.vaultID == nil }
                LabeledContent("Existing bucket") {
                    HStack {
                        Picker("Existing bucket", selection: $draft.bucket) {
                            Text(buckets.isEmpty ? "No unmanaged buckets" : "Choose…").tag("")
                            ForEach(buckets, id: \.name) { bucket in
                                Text(bucket.region.map { "\(bucket.name) · \($0)" } ?? bucket.name).tag(bucket.name)
                            }
                        }
                        .labelsHidden()
                        Button("Check Bucket") { Task { await run() } }
                            .disabled(draft.trimmedBucket.isEmpty || check.isRunning)
                    }
                }
            }
            if check.isRunning {
                LabeledContent("Checking…") { ProgressView().controlSize(.small) }
            }
            if let error = check.error {
                InlineProblem(error: error, subject: "this bucket")
            }
            if let report, report.bucket == draft.trimmedBucket {
                AdmissionReportView(report: report.report)
            } else if !draft.trimmedBucket.isEmpty {
                Text("Check the bucket before creating the vault. Nothing is changed by the check.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            }
        }
        .observing(inventory)
    }

    private func run() async {
        let bucket = draft.trimmedBucket
        guard let response = await check.run(.init(apiKeyID: apiKeyID, bucket: bucket)) else { return }
        report = (bucket, response.report)
        // The daemon recommends whether to encrypt from what the bucket already holds.
        if let recommended = response.report.recommendedEncryptUpstream { draft.encryptUpstream = recommended }
    }
}

/// The daemon's read-only admission report for adopting a bucket.
private struct AdmissionReportView: View {
    var report: WsModel.UpstreamAdmissionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !report.blockers.isEmpty {
                Callout(tone: .danger, systemImage: "xmark.octagon") {
                    Text("This bucket can't be adopted").fontWeight(.semibold)
                    ForEach(report.blockers, id: \.self) { Text("• \($0)").foregroundStyle(.fgMuted) }
                }
            }
            if !report.warnings.isEmpty {
                Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                    ForEach(report.warnings, id: \.self) { Text($0).foregroundStyle(.fgMuted) }
                }
            }
            DefinitionList(items: [
                ("Objects", "\(report.objectsScanned.formatted())\(report.truncated ? "+" : "") · \(Format.bytes(report.bytesScanned))\(report.truncated ? "+" : "")"),
                ("Sampled", report.sampled == 0 ? "Nothing to sample"
                    : "\(report.sampledVaulthallaEncrypted) encrypted by Vaulthalla, \(report.sampledPlaintext) plain"),
                ("Versioning", Format.words(report.versioning)),
                ("Object lock", report.objectLock.map { $0 ? "On" : "Off" } ?? "Unknown"),
                ("Vaulthalla data", report.hasVaulthallaManifest
                    ? "Yes\(report.manifestVaultID.map { " (vault #\($0))" } ?? "")" : "No"),
            ], termWidth: 120)
        }
        .padding(.vertical, 4)
    }
}

import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// What gateway keys may spend and have spent: active key budgets, their spend windows, and the charge ledger.
struct GatewayBudgetsTab: View {
    var node: Node
    var queries: NodeQueries
    var credentials: NodeQuery<Ws.S3.Gateway.Credentials.List>

    var body: some View {
        let policies = queries.query(Ws.S3.Gateway.Budget.Policy.List.self, .init(includeInactive: true))
        let status = queries.query(Ws.S3.Gateway.Budget.Status.self, .init(limit: 50))
        let ledger = queries.query(Ws.S3.Gateway.Budget.Ledger.List.self, .init(limit: 100))
        let vaults = queries.query(Ws.Storage.Vault.List.self)
        let vaultList = vaults.value?.vaults ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GatewaySection(title: "Key budgets",
                               subtitle: "Caps on what requests through a gateway key may cost. Select a key under Keys to change its caps.") {
                    Panel {
                        InlineQuery(query: policies, subject: "key budgets") { response in
                            let active = response.policies.filter { $0.isActive && $0.gatewayCredentialID != nil }
                            if active.isEmpty {
                                Text("No gateway key has a budget.")
                                    .font(.callout)
                                    .foregroundStyle(.fgSubtle)
                            } else {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(active, id: \.id) { policy in
                                        GatewayBudgetMeter(
                                            policy: policy,
                                            trend: status.value?.trends.first { $0.policyID == policy.id && $0.windowType == "monthly" },
                                            title: title(policy, vaults: vaultList))
                                    }
                                }
                            }
                        }
                    }
                }

                GatewaySection(title: "Budget windows") {
                    Panel {
                        InlineQuery(query: status, subject: "budget windows") { response in
                            windows(response.trends, vaults: vaultList)
                        }
                    }
                }

                GatewaySection(title: "Ledger", subtitle: "Recorded gateway request charges, newest first.") {
                    Panel {
                        InlineQuery(query: ledger, subject: "the ledger") { response in
                            GatewayLedgerRows(entries: response.ledger, vaults: vaultList, limit: 100,
                                              empty: "No gateway charges recorded yet.", credentialName: keyName)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .observing(policies)
        .observing(status, polling: .seconds(60))
        .observing(ledger)
        .observing(vaults)
    }

    private func keyName(_ id: Int64) -> String {
        credentials.value?.credentials.first { $0.id == id }?.name ?? "Key #\(id)"
    }

    private func title(_ policy: WsModel.PriceBudgetPolicy, vaults: [WsModel.Vault]) -> String {
        let key = policy.gatewayCredentialID.map(keyName) ?? "—"
        guard policy.scope == "gateway_credential_vault", let vault = policy.vaultID else { return key }
        return "\(key) on \(vaults.first { $0.id == vault }?.name ?? "Vault #\(vault)")"
    }

    @ViewBuilder
    private func windows(_ trends: [WsModel.PriceBudgetTrendStats], vaults: [WsModel.Vault]) -> some View {
        if trends.isEmpty {
            Text("No key budget has a spend window yet.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach(["Key", "Window", "Spent", "Limit", "Used", "Projected"], id: \.self) { header in
                        Text(header.uppercased())
                            .font(.caption2.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(.fgSubtle)
                    }
                }
                ForEach(Array(trends.enumerated()), id: \.offset) { _, trend in
                    GridRow {
                        Text(trend.gatewayCredentialID.map(keyName) ?? "—")
                            .foregroundStyle(.fg)
                        Text(Format.words(trend.windowType))
                            .foregroundStyle(.fgMuted)
                        Text(GatewayFormat.money(trend.totalCost, currency: trend.currency) ?? trend.totalCost)
                            .monospacedDigit()
                        Text(GatewayFormat.money(trend.limit, currency: trend.currency) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.fgMuted)
                        Text(trend.percentUsed.formatted(.number.precision(.fractionLength(0))) + "%")
                            .monospacedDigit()
                            .foregroundStyle(trend.percentUsed >= 90 ? StatusTone.warn.color : .fgMuted)
                        Text(GatewayFormat.money(trend.projectedWindowCost, currency: trend.currency) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }
            .font(.callout)
        }
    }
}

/// How to point an S3 client at the gateway, with the endpoint and a key filled in. The secret is never shown here:
/// it was shown once when the key was created.
struct GatewayClientSetup: View {
    var node: Node
    var status: Ws.S3.Gateway.Status.Response.Status?
    var credentials: NodeQuery<Ws.S3.Gateway.Credentials.List>
    var buckets: NodeQuery<Ws.S3.Gateway.Buckets.List>

    @State private var endpoint: String?
    @State private var keyID: Int64?

    var body: some View {
        let active = (credentials.value?.credentials ?? []).filter { $0.enabled && !$0.isExpired }
        let key = active.first { $0.id == keyID } ?? active.first
        let url = endpoint ?? suggested
        let accessKey = key?.accessKey ?? "<access-key-id>"
        let bucket = buckets.value?.buckets.first.map { $0.bucketName.isEmpty ? $0.bucket : $0.bucketName } ?? "<bucket>"

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Panel(title: "Client setup",
                      subtitle: "Any S3 client works. Use path-style addressing and the secret you saved when the key was created.") {
                    VStack(alignment: .leading, spacing: 12) {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                            GridRow {
                                Text("Endpoint URL")
                                    .foregroundStyle(.fgSubtle)
                                TextField("Endpoint URL", text: Binding(get: { url }, set: { endpoint = $0 }))
                                    .font(.body.monospaced())
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Key")
                                    .foregroundStyle(.fgSubtle)
                                Picker("Key", selection: Binding(get: { key?.id }, set: { keyID = $0 })) {
                                    if active.isEmpty { Text("No active keys").tag(Int64?.none) }
                                    ForEach(active, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
                                }
                                .labelsHidden()
                                .disabled(active.isEmpty)
                                .fixedSize()
                            }
                        }
                        .font(.callout)
                        if endpoint == nil, status != nil {
                            Text("Suggested from the gateway's port and the address this Mac uses for \(node.displayName). Use whatever address clients actually reach.")
                                .font(.caption)
                                .foregroundStyle(.fgSubtle)
                        }
                        if let key {
                            GatewayCopyField(label: "Access key ID", value: key.accessKey)
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], spacing: 14) {
                    snippet("Environment", """
                        export AWS_ACCESS_KEY_ID=\(accessKey)
                        export AWS_SECRET_ACCESS_KEY=<secret-access-key>
                        export AWS_EC2_METADATA_DISABLED=true
                        """)
                    snippet("AWS CLI", """
                        aws configure set s3.addressing_style path
                        aws --endpoint-url \(url) s3 ls
                        aws --endpoint-url \(url) s3 cp ./backup.tar s3://\(bucket)/backup.tar
                        """)
                    snippet("MinIO client (mc)", """
                        mc alias set vaulthalla \(url) \(accessKey) <secret-access-key>
                        mc ls vaulthalla/\(bucket)
                        """)
                    snippet("rclone", """
                        [vaulthalla]
                        type = s3
                        provider = Other
                        endpoint = \(url)
                        access_key_id = \(accessKey)
                        secret_access_key = <secret-access-key>
                        force_path_style = true
                        """)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .observing(buckets)
    }

    /// The gateway's own endpoint, or its port on the host this Mac reaches the node at when it binds every interface.
    private var suggested: String {
        guard let status else { return "http://<gateway-host>:39000" }
        if !status.endpoint.isEmpty, !["0.0.0.0", "::", "[::]", "*", ""].contains(status.host) { return status.endpoint }
        let host = node.endpoint.host.contains(":") ? "[\(node.endpoint.host)]" : node.endpoint.host
        return "http://\(host):\(status.port)"
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.fgMuted)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { GatewayFormat.copy(text) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy \(title)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView(.horizontal) {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.fg)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(12)
            }
        }
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
    }
}

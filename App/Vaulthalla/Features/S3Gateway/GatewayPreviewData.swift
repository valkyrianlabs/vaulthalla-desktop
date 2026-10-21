#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: the `s3.gateway.*` answers for `#Preview`s and `DebugSnapshot`. "Home lab (preview)"
/// answers as an admin with gateway permissions, "Studio (preview)" as an account without any. Names say "(preview)";
/// the secret a created key gets is a visibly fake placeholder.
nonisolated enum GatewayPreviewData: PreviewFeature {
    private struct State {
        var credentials: [WsModel.S3GatewayCredential]
        var buckets: [WsModel.S3GatewayBucket]
        var policies: [WsModel.PriceBudgetPolicy]
    }

    private static let now = Int64(Date.now.timeIntervalSince1970)
    private static let state = Mutex(State(credentials: credentials, buckets: buckets, policies: policies))

    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        guard command.rawValue.hasPrefix("s3.gateway.") else { return nil }
        guard transport.scenario == .full else {
            throw .denied("Permission denied: this account has no admin.s3_gateway permission.")
        }
        switch command {
        case .s3GatewayStatus:
            return Ws.S3.Gateway.Status.Response(status: .init(
                running: true, configured: true, ready: true, host: "0.0.0.0", port: 39000,
                endpoint: "http://0.0.0.0:39000", activeSessions: 2, totalRequests: 18_342, failedRequests: 27))
        case .s3GatewayCredentialsList:
            return Ws.S3.Gateway.Credentials.List.Response(credentials: state.withLock { $0.credentials })
        case .s3GatewayCredentialsCreate:
            guard let create = payload as? Ws.S3.Gateway.Credentials.Create.Payload else { throw .invalid("Bad payload.") }
            let id = Int64(state.withLock { $0.credentials.count } + 1)
            let made = credential(id, create.name, key: "VHGWPREVIEW\(id)NEWKEY", scope: create.scopeMode?.rawValue ?? "user_access",
                                  used: nil, expires: create.expiresAt?.wrapped)
            state.withLock { $0.credentials.append(made) }
            return Ws.S3.Gateway.Credentials.Create.Response(
                credential: made, secretAccessKey: "preview-secret-NOT-REAL-0000000000000000000000")
        case .s3GatewayCredentialsRevoke:
            let key = (payload as? Ws.S3.Gateway.Credentials.Revoke.Payload)?.accessKey
            state.withLock { state in
                state.credentials = state.credentials.map { var c = $0; if c.accessKey == key { c.enabled = false }; return c }
            }
            return Ws.S3.Gateway.Credentials.Revoke.Response(revoked: true)
        case .s3GatewayCredentialsScopeUpdate:
            guard let update = payload as? Ws.S3.Gateway.Credentials.Scope.Update.Payload,
                  var found = state.withLock({ $0.credentials.first { $0.accessKey == update.accessKey } })
            else { throw .notFound("No such key.") }
            if let mode = update.scopeMode { found.scopeMode = mode.rawValue }
            if let description = update.description { found.description = description.wrapped }
            if let expires = update.expiresAt { found.expiresAt = expires.wrapped }
            if let local = update.enforceBudgetForLocalRequests { found.enforceBudgetForLocalRequests = local }
            let updated = found
            state.withLock { state in state.credentials = state.credentials.map { $0.id == updated.id ? updated : $0 } }
            return Ws.S3.Gateway.Credentials.Scope.Update.Response(credential: updated)
        case .s3GatewayCredentialsDefaultRoleGet:
            let found = try lookup((payload as? Ws.S3.Gateway.Credentials.DefaultRole.Get.Payload)?.credentialID)
            return Ws.S3.Gateway.Credentials.DefaultRole.Get.Response(
                credential: found, defaultRole: found.scopeMode == "user_access" ? nil : defaultRole(found))
        case .s3GatewayCredentialsSelectedVaultsList:
            let found = try lookup((payload as? Ws.S3.Gateway.Credentials.SelectedVaults.List.Payload)?.credentialID)
            let rows = found.scopeMode == "vault_allowlist" ? [selected(found.id, 1, "Family Photos (preview)"),
                                                               selected(found.id, 3, "Offsite Backup (preview)")] : []
            return Ws.S3.Gateway.Credentials.SelectedVaults.List.Response(credential: found, selectedVaults: rows, vaults: rows)
        case .s3GatewayCredentialsDefaultRoleOverridesList:
            let found = try lookup((payload as? Ws.S3.Gateway.Credentials.DefaultRole.Overrides.List.Payload)?.credentialID)
            return Ws.S3.Gateway.Credentials.DefaultRole.Overrides.List.Response(
                credential: found, defaultRole: defaultRole(found), overrides: [])
        case .s3GatewayCredentialsRolesList:
            let found = try lookup((payload as? Ws.S3.Gateway.Credentials.Roles.List.Payload)?.credentialID)
            return Ws.S3.Gateway.Credentials.Roles.List.Response(credential: found, roles: [], assignments: [])
        case .s3GatewayCredentialsRolesOverridesList:
            let found = try lookup((payload as? Ws.S3.Gateway.Credentials.Roles.Overrides.List.Payload)?.credentialID)
            return Ws.S3.Gateway.Credentials.Roles.Overrides.List.Response(credential: found, overrides: [])
        case .s3GatewayBucketsList:
            return Ws.S3.Gateway.Buckets.List.Response(buckets: state.withLock { $0.buckets })
        case .s3GatewayBucketsUnbind:
            let name = (payload as? Ws.S3.Gateway.Buckets.Unbind.Payload)?.bucketName
            state.withLock { $0.buckets.removeAll { $0.bucketName == name } }
            return Ws.S3.Gateway.Buckets.Unbind.Response(unbound: true)
        case .s3GatewayBudgetPolicyList:
            return Ws.S3.Gateway.Budget.Policy.List.Response(policies: state.withLock { $0.policies })
        case .s3GatewayBudgetStatus:
            let filter = (payload as? Ws.S3.Gateway.Budget.Status.Payload)?.gatewayCredentialID?.wrapped
            let policies = state.withLock { $0.policies }.filter { filter == nil || $0.gatewayCredentialID == filter }
            return Ws.S3.Gateway.Budget.Status.Response(
                policies: policies, ledger: [], trends: trends.filter { filter == nil || $0.gatewayCredentialID == filter })
        case .s3GatewayBudgetLedgerList:
            let filter = (payload as? Ws.S3.Gateway.Budget.Ledger.List.Payload)?.gatewayCredentialID?.wrapped
            return Ws.S3.Gateway.Budget.Ledger.List.Response(
                ledger: ledger.filter { filter == nil || $0.gatewayCredentialID == filter })
        default:
            throw .notFound("The preview has no answer for \(command.rawValue).")
        }
    }

    private static func lookup(_ id: Int64?) throws(WsError) -> WsModel.S3GatewayCredential {
        guard let id, let found = state.withLock({ $0.credentials.first { $0.id == id } }) else {
            throw .notFound("No such key.")
        }
        return found
    }

    // MARK: Canned values

    private static let credentials: [WsModel.S3GatewayCredential] = [
        credential(1, "nightly-backup (preview)", key: "VHGW7Q2XK9PREVIEW01", scope: "vault_allowlist", used: 3_600,
                   description: "Restic from the NAS, every night at 02:00.", local: true),
        credential(2, "rclone-laptop (preview)", key: "VHGW4M8TPREVIEW02", scope: "user_access", used: 86_400 * 3,
                   expires: now + 86_400 * 45),
        credential(3, "media-sync (preview)", key: "VHGWB3NPREVIEW03", scope: "global", used: 600),
        credential(4, "old-ci (preview)", key: "VHGWZZ1PREVIEW04", scope: "user_access", used: 86_400 * 120,
                   enabled: false),
    ]

    private static func credential(_ id: Int64, _ name: String, key: String, scope: String, used: Int64?,
                                   description: String? = nil, local: Bool = false, enabled: Bool = true,
                                   expires: Int64? = nil) -> WsModel.S3GatewayCredential {
        WsModel.S3GatewayCredential(
            id: id, userID: 1, principalUserID: 1, principalUser: .init(id: 1, name: "cooper"), name: name,
            accessKey: key, enabled: enabled, scopeMode: scope, enforceBudgetForLocalRequests: local,
            description: description, createdAt: now - 86_400 * (30 * id), lastUsedAt: used.map { now - $0 },
            expiresAt: expires)
    }

    private static func role(_ id: Int64, _ name: String) -> WsModel.VaultRole {
        WsModel.VaultRole(id: id, name: name, description: "", createdAt: now, updatedAt: now, permissions: [])
    }

    private static func defaultRole(_ credential: WsModel.S3GatewayCredential) -> WsModel.S3GatewayDefaultRole {
        WsModel.S3GatewayDefaultRole(id: credential.id, defaultRoleID: credential.id, credentialID: credential.id,
                                     vaultRoleID: 2, role: role(2, "Backup writer (preview)"), enabled: true,
                                     createdAt: now, updatedAt: now)
    }

    private static func selected(_ credential: Int64, _ vault: Int64, _ name: String) -> WsModel.S3GatewaySelectedVault {
        WsModel.S3GatewaySelectedVault(
            credentialID: credential, vaultID: vault,
            vault: .init(id: vault, name: name, slug: name.lowercased(), effectiveFuseName: name.lowercased(), ownerID: 11),
            enabled: true, createdAt: now, updatedAt: now)
    }

    private static let buckets: [WsModel.S3GatewayBucket] = [
        bucket("family-photos", vault: 1, mode: "local", exclusive: false, days: 60),
        bucket("offsite-backup", vault: 3, mode: "remote_cache", exclusive: true, days: 40),
        bucket("media-archive", vault: 4, mode: "remote_proxy", exclusive: false, days: 12),
    ]

    private static func bucket(_ name: String, vault: Int64, mode: String, exclusive: Bool, days: Int64)
        -> WsModel.S3GatewayBucket
    {
        WsModel.S3GatewayBucket(bucketName: name, bucket: name, vaultID: vault, mode: mode, apiExclusive: exclusive,
                                createdAt: now - days * 86_400, updatedAt: now)
    }

    private static let policies: [WsModel.PriceBudgetPolicy] = [
        WsModel.PriceBudgetPolicy(id: 1, scope: "gateway_credential", gatewayCredentialID: 1, mode: "enforce",
                                  currency: "USD", maxMonthlyCost: "25.00", requireVerifiedCatalog: true,
                                  allowStaleCatalog: false, maxCatalogAgeSeconds: 43_200, isActive: true),
        WsModel.PriceBudgetPolicy(id: 2, scope: "gateway_credential_vault", vaultID: 3, gatewayCredentialID: 1,
                                  mode: "warn", currency: "USD", maxMonthlyCost: "10.00", requireVerifiedCatalog: true,
                                  allowStaleCatalog: false, isActive: true),
        WsModel.PriceBudgetPolicy(id: 3, scope: "gateway_credential", gatewayCredentialID: 3, mode: "report",
                                  currency: "USD", maxMonthlyCost: "40.00", requireVerifiedCatalog: true,
                                  allowStaleCatalog: false, isActive: true),
    ]

    private static let trends: [WsModel.PriceBudgetTrendStats] = [
        trend(policy: 1, credential: 1, vault: nil, spent: "18.40", limit: "25.00", percent: 73.6),
        trend(policy: 2, credential: 1, vault: 3, spent: "9.35", limit: "10.00", percent: 93.5),
        trend(policy: 3, credential: 3, vault: nil, spent: "6.10", limit: "40.00", percent: 15.3),
    ]

    private static func trend(policy: Int64, credential: Int64, vault: Int64?, spent: String, limit: String,
                              percent: Double) -> WsModel.PriceBudgetTrendStats {
        WsModel.PriceBudgetTrendStats(
            scope: vault == nil ? "gateway_credential" : "gateway_credential_vault", vaultID: vault,
            gatewayCredentialID: credential, policyID: policy, currency: "USD", windowType: "monthly",
            windowStart: "2026-10-01T00:00:00Z", windowEnd: "2026-11-01T00:00:00Z", committedCost: spent,
            reservedCost: "0.00", totalCost: spent, limit: limit, percentUsed: percent,
            projectedWindowCost: String(format: "%.2f", (Double(spent) ?? 0) * 1.45), confidence: "medium",
            recentDailyAverage: "0.90", recent7dAverage: "0.85", recent30dAverage: "0.80", warnings: [])
    }

    private static let ledger: [WsModel.PriceBudgetLedgerEntry] = (0..<8).map { index in
        let operations = ["put_object", "get_object", "list_objects", "put_object"]
        return WsModel.PriceBudgetLedgerEntry(
            id: Int64(100 - index), policyID: index % 3 == 2 ? 3 : 1, runUUID: "preview-run-\(index)",
            vaultID: index % 3 == 2 ? 4 : 3, gatewayCredentialID: index % 3 == 2 ? 3 : 1,
            operation: operations[index % operations.count], synthetic: false, providerKey: "aws-s3", currency: "USD",
            window: "monthly", windowStart: "2026-10-01T00:00:00Z", windowEnd: "2026-11-01T00:00:00Z",
            reservedCost: String(format: "%.4f", 0.0042 * Double(index + 1)),
            committedCost: String(format: "%.4f", 0.0042 * Double(index + 1)), status: "committed",
            createdAt: Date(timeIntervalSince1970: TimeInterval(now - Int64(index) * 5_400)).ISO8601Format())
    }
}
#endif

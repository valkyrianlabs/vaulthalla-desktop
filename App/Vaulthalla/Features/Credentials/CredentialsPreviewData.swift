#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: provider credentials for the preview nodes. Secrets are accepted and dropped; the
/// preview, like the daemon, never sends one back.
nonisolated enum CredentialsPreviewData: PreviewFeature {
    private static let keys = Mutex([
        key(1, "AWS production (preview)", "AWS", endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1",
            access: "AKIAPREVIEW0EXAMPLE7Q", admin: true),
        key(2, "R2 archive (preview)", "Cloudflare R2", endpoint: "https://0123456789abcdef.r2.cloudflarestorage.com",
            region: "auto", access: "f1e2d3c4b5a6preview9988", admin: false),
    ])

    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        let denied = WsError.denied("Permission denied: viewing provider credentials needs an admin.keys.api permission.")
        switch command {
        case .storageApiKeyList:
            guard transport.scenario == .full else { throw denied }
            return Ws.Storage.ApiKey.List.Response(keys: keys.withLock { $0 })
        case .storageApiKeyGet:
            guard let id = (payload as? Ws.Storage.ApiKey.Get.Payload)?.id,
                  let found = keys.withLock({ $0.first { $0.apiKeyID == id } }) else { throw .notFound("No such API key.") }
            return Ws.Storage.ApiKey.Get.Response(apiKey: found)
        case .storageApiKeyAdd:
            guard let add = payload as? Ws.Storage.ApiKey.Add.Payload else { throw .invalid("Bad payload.") }
            return keys.withLock { list in
                let made = key((list.map(\.apiKeyID).max() ?? 0) + 1, add.name, add.provider.rawValue,
                               endpoint: add.endpoint, region: add.region ?? "auto", access: add.accessKey, admin: false)
                list.append(made)
                return Ws.Storage.ApiKey.Add.Response(apiKey: made)
            }
        case .storageApiKeyUpdate:
            guard let patch = payload as? Ws.Storage.ApiKey.Update.Payload else { throw .invalid("Bad payload.") }
            return try keys.withLock { list throws(WsError) in
                guard let index = list.firstIndex(where: { $0.apiKeyID == patch.id }) else { throw .notFound("No such API key.") }
                if let name = patch.name?.wrapped { list[index].name = name }
                if let provider = patch.provider?.wrapped { list[index].provider = provider.rawValue }
                if let endpoint = patch.endpoint?.wrapped { list[index].endpoint = endpoint }
                if let region = patch.region?.wrapped { list[index].region = region }
                if let access = patch.accessKey?.wrapped { list[index].accessKey = access }
                return Ws.Storage.ApiKey.Update.Response(apiKey: list[index])
            }
        case .storageApiKeyRemove:
            guard let id = (payload as? Ws.Storage.ApiKey.Remove.Payload)?.id else { throw .invalid("Bad payload.") }
            let users = transport.vaults.withLock { $0.filter { $0.apiKeyID == id }.map(\.name) }
            if !users.isEmpty {
                throw .invalid("API key is in use by vault(s): \(users.joined(separator: ", ")). Move or delete them first.")
            }
            keys.withLock { $0.removeAll { $0.apiKeyID == id } }
            return WsEmpty()
        default:
            return nil
        }
    }

    private static func key(_ id: Int64, _ name: String, _ provider: String, endpoint: String, region: String,
                            access: String, admin: Bool) -> WsModel.APIKey {
        WsModel.APIKey(apiKeyID: id, userID: 1, name: name, createdAt: "2026-0\(id + 2)-0\(id + 3)T10:00:00Z",
                       provider: provider, accessKey: access, region: region, endpoint: endpoint, adminEnabled: admin,
                       providerAccountID: admin ? "123456789012" : nil, hasProviderToken: false,
                       adminValidatedAt: admin ? "2026-10-01T10:00:00Z" : nil)
    }
}
#endif

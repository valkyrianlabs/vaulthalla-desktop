#if DEBUG
import Foundation
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: creating vaults, and the bucket inventory and adoption check of the preview's
/// admin-enabled credential. Adopting asks `upstream_adoption`; a bucket that already holds plain files asks
/// `encryption_waiver`, as the daemon does.
nonisolated enum NewVaultPreviewData: PreviewFeature {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        switch command {
        case .storageVaultAdd:
            guard let add = payload as? Ws.Storage.Vault.Add.Payload else { throw .invalid("Bad payload.") }
            guard transport.scenario == .full else { throw .denied("Permission denied: your role can't create vaults.") }
            let provision = add.provision?.wrapped
            if provision?.mode?.wrapped == .adopt, provision?.acceptAdoption?.wrapped != true {
                throw .needsConfirmation(
                    code: "upstream_adoption",
                    message: "Adopt “\(add.bucket ?? "")”? Vaulthalla starts managing its lifecycle and event rules; the 1,204 objects in it stay as they are and are indexed into the new vault.")
            }
            if add.type == .s3, add.encryptUpstream == true, add.bucket == "legacy-photos", add.acceptEncryptionWaiver != true {
                throw .needsConfirmation(
                    code: "encryption_waiver",
                    message: "“legacy-photos” already holds 1,204 objects Vaulthalla did not write. They stay readable as plain files; only new uploads are encrypted.")
            }
            return transport.vaults.withLock { list in
                let id = (list.map(\.id).max() ?? 0) + 1
                let slug = add.slug ?? add.name.lowercased().replacingOccurrences(of: " ", with: "-")
                let vault = WsModel.Vault(
                    id: id, name: add.name, slug: slug, effectiveFuseName: add.fuseName?.wrapped ?? slug,
                    type: add.type.rawValue, description: add.description ?? "", quota: add.quota ?? 0, ownerID: 11,
                    mountPoint: slug, allowFsWrite: true, isActive: true, createdAt: "2026-10-21T09:00:00Z",
                    apiKeyID: add.apiKeyID, bucket: add.type == .s3 ? (add.bucket?.isEmpty == false ? add.bucket : "project-archive-7f3a") : nil,
                    encryptUpstream: add.type == .s3 ? add.encryptUpstream : nil, owner: "cooper")
                list.append(vault)
                return Ws.Storage.Vault.Add.Response(vault: vault)
            }
        case .upstreamBucketList:
            guard let list = payload as? Ws.Upstream.Bucket.List.Payload else { throw .invalid("Bad payload.") }
            guard list.apiKeyID == 1 else { throw .invalid("Provider administration is not enabled for this credential.") }
            return Ws.Upstream.Bucket.List.Response(inventory: .init(
                apiKeyID: 1, provider: "aws-s3", accountRef: "123456789012",
                buckets: [bucket("legacy-photos", "us-east-1"), bucket("old-backups-2021", "us-west-2")], nextToken: ""))
        case .upstreamBucketAdoptPreflight:
            guard let check = payload as? Ws.Upstream.Bucket.Adopt.Preflight.Payload else { throw .invalid("Bad payload.") }
            let legacy = check.bucket == "legacy-photos"
            return Ws.Upstream.Bucket.Adopt.Preflight.Response(report: .init(
                bucket: bucket(check.bucket, "us-east-1"), objectsScanned: legacy ? 1204 : 88,
                bytesScanned: legacy ? 7_400_000_000 : 210_000_000, truncated: false, hasVaulthallaManifest: false,
                sampled: legacy ? 8 : 4, sampledVaulthallaEncrypted: 0, sampledPlaintext: legacy ? 8 : 4,
                sampleKeys: [], versioning: legacy ? "enabled" : "unversioned", objectLock: false, blockers: [],
                warnings: legacy ? ["Versioning is on: noncurrent versions keep costing storage until a lifecycle rule expires them."] : [],
                recommendedEncryptUpstream: false))
        default:
            return nil
        }
    }

    private static func bucket(_ name: String, _ region: String) -> WsModel.UpstreamBucketRow {
        WsModel.UpstreamBucketRow(name: name, region: region, state: "unmanaged", ownership: "unmanaged",
                                  provisioningState: "none", isProtected: false, listed: true)
    }
}
#endif

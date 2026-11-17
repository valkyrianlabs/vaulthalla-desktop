import Foundation
public import VHCloud

/// The cloud's short-lived bucket key as the S3 store signs with it: lent per request by ``DeviceAccess``, which
/// renews it by itself. A 401 or 403 from the provider makes DeviceAccess read the cloud's view at its next step and ask
/// for a new key.
extension DeviceAccess: S3CredentialSource {
    public func withS3Credentials<R: Sendable>(_ body: @Sendable (S3Credentials) throws -> R) rethrows -> R? {
        try withCredentials { (c: Credentials) in
            try body(S3Credentials(accessKeyID: c.accessKeyID, secret: c.secret, bucket: c.bucket, endpoint: c.s3Endpoint,
                                   region: c.region))
        }
    }

    public func providerRefused() { providerRefusedKey() }
}

extension DesktopVaultSession: EngineHost {}

/// A key the person brings (their own, after an ejection), lent to a store only to check it reaches the vault's bucket
/// before anything switches to it (``DesktopVaults/useOwnKey(_:keyID:secret:)``).
final class OwnKeyCredentials: S3CredentialSource, @unchecked Sendable {
    let key: BucketKey

    init(_ key: BucketKey) { self.key = key }

    func withS3Credentials<R: Sendable>(_ body: @Sendable (S3Credentials) throws -> R) async rethrows -> R? {
        try key.secret.withUnsafeBytes { secret in
            try body(S3Credentials(accessKeyID: key.keyID, secret: secret, bucket: key.bucket, endpoint: key.s3Endpoint,
                                   region: key.region))
        }
    }

    func providerRefused() async {}  // the check reports the refusal itself
}

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

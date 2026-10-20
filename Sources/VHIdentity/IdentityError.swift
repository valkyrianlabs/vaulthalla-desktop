public import Foundation

/// Why an identity operation failed. Messages name the operation and the Security.framework status; they never carry
/// key material, certificate bytes or anything derived from the private key.
public enum IdentityError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A Keychain call returned `status`. `operation` says which one ("add certificate", "copy identity", ...).
    case keychain(operation: String, status: OSStatus)
    /// The process lacks the entitlements the requested Keychain or Secure Enclave operation needs
    /// (`errSecMissingEntitlement`, -34018). Expected under `swift test` and in unsigned builds.
    case missingEntitlement(operation: String)
    /// `SecKeyCreateRandomKey` failed for a reason other than entitlements.
    case keyGeneration(String)
    /// A key that isn't an EC P-256 key reached an API that only speaks P-256.
    case unsupportedKey(String)
    /// A fixed-length protocol field had the wrong length.
    case invalidLength(field: String, expected: Int, actual: Int)
    /// Building, parsing or importing a certificate failed.
    case certificate(String)
    /// Signing with the device key failed.
    case signing(String)
    /// No identity is stored for the node tag.
    case notFound(nodeTag: String)
    /// The node already has an identity; replacing it would silently unpair the node.
    case alreadyExists(nodeTag: String)
    /// Node tags are 1–128 ASCII characters from `[A-Za-z0-9._:-]`.
    case invalidNodeTag(String)
    /// `completeRotation`/`cancelRotation` found no pending replacement identity.
    case noPendingRotation(nodeTag: String)

    public var description: String {
        switch self {
        case .keychain(let operation, let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain \(operation) failed: \(status) (\(message))"
        case .missingEntitlement(let operation):
            return "Keychain \(operation) needs a signed app with keychain entitlements (errSecMissingEntitlement)"
        case .keyGeneration(let reason): return "Key generation failed: \(reason)"
        case .unsupportedKey(let reason): return "Unsupported key: \(reason)"
        case .invalidLength(let field, let expected, let actual):
            return "\(field) must be \(expected) bytes, got \(actual)"
        case .certificate(let reason): return "Certificate error: \(reason)"
        case .signing(let reason): return "Signing failed: \(reason)"
        case .notFound(let nodeTag): return "No device identity for node \(nodeTag)"
        case .alreadyExists(let nodeTag): return "Node \(nodeTag) already has a device identity"
        case .invalidNodeTag(let nodeTag): return "Invalid node tag \"\(nodeTag)\""
        case .noPendingRotation(let nodeTag): return "No pending identity rotation for node \(nodeTag)"
        }
    }

    /// Maps a Keychain status to an error, singling out the missing-entitlement case callers branch on.
    static func keychain(_ operation: String, _ status: OSStatus) -> IdentityError {
        status == errSecMissingEntitlement
            ? .missingEntitlement(operation: operation) : .keychain(operation: operation, status: status)
    }
}

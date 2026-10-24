import Foundation
import Security

/// Every Keychain dictionary ``DeviceIdentityStore`` passes to `SecItem*` and `SecKeyCreateRandomKey`, built without
/// touching the Keychain so tests can pin their shape per ``DeviceIdentityStore/Keychain``.
///
/// The two keychains disagree about identity queries (`kSecClassIdentity`), so that one query differs by keychain:
///
/// | Query | `.fileBased` | `.dataProtection` |
/// |---|---|---|
/// | private key | tag + label | tag + label |
/// | certificates of a key | `kSecAttrPublicKeyHash` | `kSecAttrPublicKeyHash` |
/// | identity of a certificate | `kSecMatchItemList` = [certificate] | `kSecAttrApplicationLabel` = the key's label |
///
/// The file-based keychain ignores key attributes in identity queries (it returns unrelated identities), so it can only
/// be pinned to the certificate with `kSecMatchItemList`. The data protection keychain answers `errSecParam` (-50) to
/// an identity query with `kSecMatchItemList`, and `errSecNotAvailable` (-25291) to one by `kSecAttrPublicKeyHash`,
/// but it honors the key's `kSecAttrApplicationLabel` (vaulthalla/desktop#11, found by the #2 spike). The
/// application label is the SHA-1 of the public key, the same value as the certificate's public-key hash, so it names
/// exactly the identities of our key. Either way the store then checks that the identity's certificate is the one it
/// found (byte for byte), and that certificate was already checked to carry our key's SPKI.
///
/// Key and certificate queries work unchanged in both keychains. Data protection queries also carry
/// `kSecUseDataProtectionKeychain` and the configured access group; file-based ones never do. The data protection
/// paths need a team-signed process, so `tools/keychain-proof/run.sh` exercises them against the real keychain.
struct KeychainQueries: Sendable {
    let keychain: DeviceIdentityStore.Keychain
    let accessGroup: String?

    init(keychain: DeviceIdentityStore.Keychain, accessGroup: String?) {
        self.keychain = keychain
        self.accessGroup = accessGroup
    }

    init(_ configuration: DeviceIdentityStore.Configuration) {
        self.init(keychain: configuration.keychain, accessGroup: configuration.accessGroup)
    }

    /// AfterFirstUnlock, not WhenUnlocked: the menu bar extra and the MCP bridge reconnect while the screen is locked.
    /// ThisDeviceOnly: a device key must never migrate to another Mac through a backup.
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    /// The private key of one slot, matched by its namespaced tag and label (both honored by both keychains).
    func key(_ name: DeviceIdentityStore.KeyName) -> [CFString: Any] {
        scoped([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: name.tag,
            kSecAttrLabel: name.label,
        ])
    }

    /// The certificates whose public-key hash is `publicKeyHash` (a key's `kSecAttrApplicationLabel`).
    func certificates(publicKeyHash: Data) -> [CFString: Any] {
        scoped([kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: publicKeyHash])
    }

    /// The identity pairing `certificate` with the private key whose application label is `applicationLabel`.
    ///
    /// The data protection form asks for every match (a leftover second certificate for the same key would otherwise
    /// make the answer arbitrary); the caller keeps only the identity of `certificate`.
    func identity(certificate: SecCertificate, applicationLabel: Data) -> [CFString: Any] {
        switch keychain {
        case .fileBased:
            [
                kSecClass: kSecClassIdentity,
                kSecMatchItemList: [certificate],
                kSecReturnRef: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
        case .dataProtection:
            scoped([
                kSecClass: kSecClassIdentity,
                kSecAttrApplicationLabel: applicationLabel,
                kSecReturnRef: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ])
        }
    }

    /// Attributes for storing `certificate`.
    func addCertificate(_ certificate: SecCertificate) -> [CFString: Any] {
        var attributes: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecValueRef: certificate]
        if keychain == .dataProtection { attributes[kSecAttrAccessible] = Self.accessibility }
        return scoped(attributes)
    }

    /// Parameters for `SecKeyCreateRandomKey`: a permanent P-256 private key named `name`. `accessControl` is required
    /// for (and only used by) the Secure Enclave: `privateKeyUsage` with ``accessibility``.
    func keyGeneration(
        _ name: DeviceIdentityStore.KeyName, backend: KeyBackend, accessControl: SecAccessControl?
    ) -> [CFString: Any] {
        var privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: name.tag,
            kSecAttrLabel: name.label,
        ]
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        switch backend {
        case .secureEnclave:
            attributes[kSecAttrTokenID] = kSecAttrTokenIDSecureEnclave
            privateAttributes[kSecAttrAccessControl] = accessControl
        case .software:
            privateAttributes[kSecAttrIsExtractable] = false
            if keychain == .dataProtection { privateAttributes[kSecAttrAccessible] = Self.accessibility }
        }
        attributes[kSecPrivateKeyAttrs] = privateAttributes
        return scoped(attributes)
    }

    /// Adds the data protection keychain flag and the access group; leaves file-based queries unscoped.
    func scoped(_ query: [CFString: Any]) -> [CFString: Any] {
        guard keychain == .dataProtection else { return query }
        var query = query
        query[kSecUseDataProtectionKeychain] = true
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }
}

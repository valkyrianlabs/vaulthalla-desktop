import Foundation
import Security
import Testing
@testable import VHIdentity

/// Pins the shape of every Keychain query ``DeviceIdentityStore`` issues, per keychain. Pure: nothing here touches the
/// Keychain, so it runs everywhere, including unsigned `swift test`, where the data protection paths can't run.
///
/// The data protection keychain answers `errSecParam` to an identity query with `kSecMatchItemList` and
/// `errSecNotAvailable` to one by `kSecAttrPublicKeyHash` (vaulthalla/desktop#11), which made every signed build fail
/// to create or find a Secure Enclave identity.
@Suite struct KeychainQueriesTests {
    static let group = "QG2U5HNCG4.sh.vaulthalla.desktop"
    static let name = DeviceIdentityStore.KeyName(
        tag: Data("sh.vaulthalla.desktop.device/node-a".utf8), label: "sh.vaulthalla.desktop.device/node-a")
    static let label = Data((0..<20).map { UInt8($0) })

    static func queries(_ keychain: DeviceIdentityStore.Keychain, group: String? = Self.group) -> KeychainQueries {
        KeychainQueries(keychain: keychain, accessGroup: group)
    }

    static func certificate() throws -> SecCertificate {
        let der = try DeviceCertificate.make(privateKey: try ephemeralKey(), commonName: "Vaulthalla Desktop test")
        return try DeviceCertificate.secCertificate(der: der)
    }

    // MARK: Identity

    @Test func dataProtectionIdentityMatchesTheKeysApplicationLabel() throws {
        let certificate = try Self.certificate()
        let query = Self.queries(.dataProtection).identity(certificate: certificate, applicationLabel: Self.label)
        #expect(string(query[kSecClass]) == kSecClassIdentity as String)
        #expect(query[kSecAttrApplicationLabel] as? Data == Self.label)
        #expect(query[kSecMatchItemList] == nil, "errSecParam in the data protection keychain")
        #expect(query[kSecAttrPublicKeyHash] == nil, "errSecNotAvailable in the data protection keychain")
        #expect(query[kSecReturnRef] as? Bool == true)
        #expect(string(query[kSecMatchLimit]) == kSecMatchLimitAll as String)
        #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
        #expect(query[kSecAttrAccessGroup] as? String == Self.group)
        let expectedKeys: [CFString] = [
            kSecClass, kSecAttrApplicationLabel, kSecReturnRef, kSecMatchLimit, kSecUseDataProtectionKeychain,
            kSecAttrAccessGroup,
        ]
        #expect(Set(query.keys.map { $0 as String }) == Set(expectedKeys.map { $0 as String }))
    }

    @Test func dataProtectionIdentityWithoutGroupUsesTheDefaultGroup() throws {
        let query = Self.queries(.dataProtection, group: nil)
            .identity(certificate: try Self.certificate(), applicationLabel: Self.label)
        #expect(query[kSecAttrAccessGroup] == nil)
        #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
        #expect(query[kSecMatchItemList] == nil)
    }

    /// The file-based keychain ignores key attributes in identity queries, so it stays pinned to the certificate.
    @Test func fileBasedIdentityMatchesTheCertificate() throws {
        let certificate = try Self.certificate()
        let query = Self.queries(.fileBased).identity(certificate: certificate, applicationLabel: Self.label)
        #expect(string(query[kSecClass]) == kSecClassIdentity as String)
        let items = try #require(query[kSecMatchItemList] as? [SecCertificate])
        #expect(items.count == 1)
        #expect(SecCertificateCopyData(items[0]) as Data == SecCertificateCopyData(certificate) as Data)
        #expect(query[kSecAttrApplicationLabel] == nil)
        #expect(query[kSecReturnRef] as? Bool == true)
        #expect(string(query[kSecMatchLimit]) == kSecMatchLimitOne as String)
        #expect(query[kSecUseDataProtectionKeychain] == nil)
        #expect(query[kSecAttrAccessGroup] == nil, "access groups are a data protection keychain concept")
    }

    // MARK: Keys and certificates

    @Test(arguments: [DeviceIdentityStore.Keychain.dataProtection, .fileBased])
    func keyQueryMatchesTagAndLabel(_ keychain: DeviceIdentityStore.Keychain) {
        let query = Self.queries(keychain).key(Self.name)
        #expect(string(query[kSecClass]) == kSecClassKey as String)
        #expect(string(query[kSecAttrKeyClass]) == kSecAttrKeyClassPrivate as String)
        #expect(query[kSecAttrApplicationTag] as? Data == Self.name.tag)
        #expect(query[kSecAttrLabel] as? String == Self.name.label)
        expectScope(query, keychain)
    }

    @Test(arguments: [DeviceIdentityStore.Keychain.dataProtection, .fileBased])
    func certificateQueryMatchesThePublicKeyHash(_ keychain: DeviceIdentityStore.Keychain) {
        let query = Self.queries(keychain).certificates(publicKeyHash: Self.label)
        #expect(string(query[kSecClass]) == kSecClassCertificate as String)
        #expect(query[kSecAttrPublicKeyHash] as? Data == Self.label)
        #expect(query[kSecMatchItemList] == nil)
        expectScope(query, keychain)
    }

    @Test(arguments: [DeviceIdentityStore.Keychain.dataProtection, .fileBased])
    func addCertificateAttributes(_ keychain: DeviceIdentityStore.Keychain) throws {
        let certificate = try Self.certificate()
        let attributes = Self.queries(keychain).addCertificate(certificate)
        #expect(string(attributes[kSecClass]) == kSecClassCertificate as String)
        let value = try #require(attributes[kSecValueRef] as CFTypeRef?)
        #expect(CFGetTypeID(value) == SecCertificateGetTypeID())
        #expect(
            string(attributes[kSecAttrAccessible])
                == (keychain == .dataProtection ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String : nil))
        expectScope(attributes, keychain)
    }

    @Test func secureEnclaveKeyGeneration() throws {
        var error: Unmanaged<CFError>?
        let access = try #require(SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error))
        let attributes = Self.queries(.dataProtection)
            .keyGeneration(Self.name, backend: .secureEnclave, accessControl: access)
        #expect(string(attributes[kSecAttrKeyType]) == kSecAttrKeyTypeECSECPrimeRandom as String)
        #expect(attributes[kSecAttrKeySizeInBits] as? Int == 256)
        #expect(string(attributes[kSecAttrTokenID]) == kSecAttrTokenIDSecureEnclave as String)
        expectScope(attributes, .dataProtection)
        let privateAttributes = try #require(attributes[kSecPrivateKeyAttrs] as? [CFString: Any])
        #expect(privateAttributes[kSecAttrIsPermanent] as? Bool == true)
        #expect(privateAttributes[kSecAttrApplicationTag] as? Data == Self.name.tag)
        #expect(privateAttributes[kSecAttrLabel] as? String == Self.name.label)
        let stored = try #require(privateAttributes[kSecAttrAccessControl] as CFTypeRef?)
        #expect(CFGetTypeID(stored) == SecAccessControlGetTypeID())
        // The access control carries the accessibility; a separate kSecAttrAccessible would conflict with it.
        #expect(privateAttributes[kSecAttrAccessible] == nil)
        #expect(privateAttributes[kSecAttrIsExtractable] == nil)
    }

    @Test(arguments: [DeviceIdentityStore.Keychain.dataProtection, .fileBased])
    func softwareKeyGeneration(_ keychain: DeviceIdentityStore.Keychain) throws {
        let attributes = Self.queries(keychain).keyGeneration(Self.name, backend: .software, accessControl: nil)
        #expect(attributes[kSecAttrTokenID] == nil)
        expectScope(attributes, keychain)
        let privateAttributes = try #require(attributes[kSecPrivateKeyAttrs] as? [CFString: Any])
        #expect(privateAttributes[kSecAttrIsPermanent] as? Bool == true)
        #expect(privateAttributes[kSecAttrIsExtractable] as? Bool == false)
        #expect(privateAttributes[kSecAttrAccessControl] == nil)
        #expect(
            string(privateAttributes[kSecAttrAccessible])
                == (keychain == .dataProtection ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String : nil))
    }

    /// The regression guard for #11 across every query the store builds: nothing sent to the data protection keychain
    /// carries `kSecMatchItemList`, and no identity query there matches by public-key hash.
    @Test func noDataProtectionQueryUsesAttributesItRejects() throws {
        let certificate = try Self.certificate()
        for group in [Self.group, nil] {
            let queries = Self.queries(.dataProtection, group: group)
            let all = [
                queries.key(Self.name),
                queries.certificates(publicKeyHash: Self.label),
                queries.identity(certificate: certificate, applicationLabel: Self.label),
                queries.addCertificate(certificate),
                queries.keyGeneration(Self.name, backend: .software, accessControl: nil),
            ]
            for query in all {
                #expect(query[kSecMatchItemList] == nil)
                #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
                if string(query[kSecClass]) == kSecClassIdentity as String {
                    #expect(query[kSecAttrPublicKeyHash] == nil)
                }
            }
        }
    }

    /// The store builds its queries from its configuration.
    @Test func storeConfigurationSelectsTheQueries() {
        let configuration = DeviceIdentityStore.Configuration(
            namespace: "sh.vaulthalla.desktop.test", accessGroup: Self.group, keychain: .dataProtection)
        let queries = KeychainQueries(configuration)
        #expect(queries.keychain == .dataProtection)
        #expect(queries.accessGroup == Self.group)
    }

    // MARK: Helpers

    private func expectScope(
        _ query: [CFString: Any], _ keychain: DeviceIdentityStore.Keychain,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch keychain {
        case .dataProtection:
            #expect(query[kSecUseDataProtectionKeychain] as? Bool == true, sourceLocation: sourceLocation)
            #expect(query[kSecAttrAccessGroup] as? String == Self.group, sourceLocation: sourceLocation)
        case .fileBased:
            #expect(query[kSecUseDataProtectionKeychain] == nil, sourceLocation: sourceLocation)
            #expect(query[kSecAttrAccessGroup] == nil, sourceLocation: sourceLocation)
        }
    }

    private func string(_ value: Any?) -> String? { value as? String }
}

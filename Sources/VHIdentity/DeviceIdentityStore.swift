public import Foundation
import Security

/// Creates, finds, rotates and deletes device identities in the Keychain, one per node.
///
/// An actor so that the multi-step operations (generate key, issue certificate, store it, read back the identity;
/// or swap the pending identity into place) never interleave within a process. Use one store per process for a
/// given ``Configuration/namespace``.
///
/// Keychain layout, per node tag `T` and namespace `N`:
/// - private key: `kSecAttrApplicationTag` = `N/T`; `kSecAttrLabel` = `N/T`, or `N/T#next` for the replacement
///   during a rotation. Completing a rotation changes only the label, because the file-based keychain silently
///   ignores updates to the application tag.
/// - certificate: found through its `kSecAttrPublicKeyHash`, which equals the key's `kSecAttrApplicationLabel`. That
///   is also how the Keychain pairs the two into a `SecIdentity`.
///
/// Why not query by certificate label or query `kSecClassIdentity` by tag or label: the file-based keychain ignores a
/// label passed when adding a certificate, and it ignores `kSecAttrLabel`/`kSecAttrApplicationTag` in identity
/// queries, returning unrelated identities. So every lookup starts from the key (whose tag and label are honored),
/// reaches the certificate by public-key hash (re-checked by SPKI), asks for the identity of exactly that key and
/// certificate, and checks the identity's certificate is that certificate before using it. How the identity is asked
/// for differs by keychain (the data protection keychain rejects `kSecMatchItemList` there): see ``KeychainQueries``.
public actor DeviceIdentityStore {
    /// Where and under which names identities are stored.
    public struct Configuration: Sendable, Hashable {
        /// Prefix for every label and application tag the store writes. Tests use a unique namespace per run so they
        /// can only ever see and delete their own items.
        public var namespace: String
        /// Keychain access group (`<TEAMID>.sh.vaulthalla.app`) shared with the app's helpers; `nil` uses the
        /// app's default group.
        public var accessGroup: String?
        public var keychain: Keychain

        public init(
            namespace: String = "sh.vaulthalla.app.device",
            accessGroup: String? = nil,
            keychain: Keychain = .dataProtection
        ) {
            self.namespace = namespace
            self.accessGroup = accessGroup
            self.keychain = keychain
        }
    }

    /// Which macOS keychain implementation holds the items.
    public enum Keychain: Sendable, Hashable {
        /// The iOS-style data protection keychain (`kSecUseDataProtectionKeychain`). Production: the only one that
        /// holds Secure Enclave keys and honors access groups. Needs a signed app with keychain entitlements.
        case dataProtection
        /// The file-based login keychain. For tests and unsigned tools, which can't use the data protection keychain;
        /// software keys only.
        case fileBased
    }

    public let configuration: Configuration
    private let queries: KeychainQueries

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.queries = KeychainQueries(configuration)
    }

    // MARK: Public API

    /// Generates a key on `backend`, issues its self-signed certificate for `deviceName`, and stores both.
    ///
    /// - Throws: ``IdentityError/alreadyExists(nodeTag:)`` if the node already has an identity (delete it first: a
    ///   new identity means pairing again); ``IdentityError/missingEntitlement(operation:)`` when the process can't
    ///   use the data protection keychain or the Secure Enclave.
    public func createIdentity(
        for nodeTag: String, deviceName: String, backend: KeyBackend, now: Date = .now
    ) throws -> DeviceIdentity {
        let name = try keyName(for: nodeTag, slot: .current)
        if try copyIdentity(name) != nil { throw IdentityError.alreadyExists(nodeTag: nodeTag) }
        return try makeIdentity(nodeTag: nodeTag, name: name, deviceName: deviceName, backend: backend, now: now)
    }

    /// The node's current identity, or `nil` if it has none.
    public func identity(for nodeTag: String) throws -> DeviceIdentity? {
        guard let secIdentity = try copyIdentity(keyName(for: nodeTag, slot: .current)) else { return nil }
        return try DeviceIdentity(nodeTag: nodeTag, secIdentity: secIdentity)
    }

    /// Deletes the node's identity and any pending replacement. Succeeds if there was nothing to delete.
    public func deleteIdentity(for nodeTag: String) throws {
        try deleteItems(keyName(for: nodeTag, slot: .next))
        try deleteItems(keyName(for: nodeTag, slot: .current))
    }

    /// Starts a key rotation: creates the replacement identity (same backend and device name unless overridden) and
    /// signs the rotation proof with the current key. The current identity stays in place; send the proof with
    /// `device.identity.rotate`, then call ``completeRotation(for:)`` once the daemon accepts it.
    ///
    /// If a replacement is already pending (an earlier attempt didn't finish), it's reused and a fresh proof is
    /// signed, so a retry never strands a key the daemon may already have recorded.
    public func rotate(
        for nodeTag: String,
        serverSPKISHA256: Data,
        deviceName: String? = nil,
        backend: KeyBackend? = nil,
        now: Date = .now
    ) throws -> IdentityRotation {
        guard let current = try identity(for: nodeTag) else { throw IdentityError.notFound(nodeTag: nodeTag) }
        let replacement: DeviceIdentity
        if let pending = try pendingRotation(for: nodeTag) {
            replacement = pending
        } else {
            replacement = try makeIdentity(
                nodeTag: nodeTag,
                name: keyName(for: nodeTag, slot: .next),
                deviceName: deviceName ?? current.deviceName,
                backend: backend ?? current.backend,
                now: now)
        }
        let proof = try RotationProof.sign(
            oldKey: current.privateKey,
            newCertificateDER: replacement.certificateDER,
            serverSPKISHA256: serverSPKISHA256,
            at: now)
        return IdentityRotation(current: current, replacement: replacement, proof: proof)
    }

    /// The replacement identity of an unfinished rotation, if any.
    public func pendingRotation(for nodeTag: String) throws -> DeviceIdentity? {
        guard let secIdentity = try copyIdentity(keyName(for: nodeTag, slot: .next)) else { return nil }
        return try DeviceIdentity(nodeTag: nodeTag, secIdentity: secIdentity)
    }

    /// Makes the pending replacement the node's identity and deletes the old key and certificate.
    @discardableResult
    public func completeRotation(for nodeTag: String) throws -> DeviceIdentity {
        let current = try keyName(for: nodeTag, slot: .current)
        let next = try keyName(for: nodeTag, slot: .next)
        guard try copyIdentity(next) != nil else { throw IdentityError.noPendingRotation(nodeTag: nodeTag) }
        try deleteItems(current)
        try relabel(next, to: current)
        guard let identity = try identity(for: nodeTag) else { throw IdentityError.notFound(nodeTag: nodeTag) }
        return identity
    }

    /// Discards a pending replacement (the daemon refused it, or the user gave up).
    public func cancelRotation(for nodeTag: String) throws {
        let next = try keyName(for: nodeTag, slot: .next)
        guard try copyIdentity(next) != nil else { throw IdentityError.noPendingRotation(nodeTag: nodeTag) }
        try deleteItems(next)
    }

    // MARK: Naming

    enum Slot { case current, next }

    /// The attributes that identify one slot's private key.
    struct KeyName {
        /// `N/T`, shared by both slots of a node.
        let tag: Data
        /// `N/T` or `N/T#next`.
        let label: String
    }

    /// Node tags become part of Keychain names, so they're restricted to characters that can't collide with the
    /// `/` and `#` separators.
    func keyName(for nodeTag: String, slot: Slot) throws -> KeyName {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:"))
        guard !nodeTag.isEmpty, nodeTag.count <= 128, nodeTag.allSatisfy(\.isASCII),
            nodeTag.unicodeScalars.allSatisfy(allowed.contains)
        else { throw IdentityError.invalidNodeTag(nodeTag) }
        let base = "\(configuration.namespace)/\(nodeTag)"
        return KeyName(tag: Data(base.utf8), label: slot == .current ? base : base + "#next")
    }

    // MARK: Keychain

    private func makeIdentity(
        nodeTag: String, name: KeyName, deviceName: String, backend: KeyBackend, now: Date
    ) throws -> DeviceIdentity {
        // Clear leftovers of an interrupted earlier attempt in this slot (only ever our own namespace).
        try deleteItems(name)
        let key = try generateKey(name, backend: backend)
        do {
            let der = try DeviceCertificate.make(
                privateKey: key, commonName: DeviceCertificate.commonName(deviceName: deviceName), now: now)
            try addCertificate(DeviceCertificate.secCertificate(der: der))
            guard let secIdentity = try copyIdentity(name) else {
                throw IdentityError.certificate("the Keychain didn't pair the certificate with its key")
            }
            return try DeviceIdentity(nodeTag: nodeTag, secIdentity: secIdentity)
        } catch {
            try? deleteItems(name)
            throw error
        }
    }

    private func generateKey(_ name: KeyName, backend: KeyBackend) throws -> SecKey {
        var accessControl: SecAccessControl?
        if backend == .secureEnclave {
            // privateKeyUsage only: no user presence, so TLS handshakes never prompt.
            var error: Unmanaged<CFError>?
            accessControl = SecAccessControlCreateWithFlags(
                nil, KeychainQueries.accessibility, .privateKeyUsage, &error)
            if accessControl == nil { throw IdentityError.keyGeneration(describe(error)) }
        }
        let attributes = queries.keyGeneration(name, backend: backend, accessControl: accessControl)

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let cfError = error?.takeRetainedValue()
            if let cfError, CFErrorGetCode(cfError) == Int(errSecMissingEntitlement) {
                throw IdentityError.missingEntitlement(operation: "create \(backend.rawValue) key")
            }
            let reason = cfError.flatMap { CFErrorCopyDescription($0) as String? } ?? "unknown error"
            throw IdentityError.keyGeneration(reason)
        }
        return key
    }

    private func addCertificate(_ certificate: SecCertificate) throws {
        let status = SecItemAdd(queries.addCertificate(certificate) as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.keychain("add certificate", status) }
    }

    /// The private key stored in the slot and its application label (SHA-1 of the public key), or `nil`.
    private func copyKey(_ name: KeyName) throws -> (key: SecKey, applicationLabel: Data)? {
        var query = queries.key(name)
        query[kSecReturnRef] = true
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IdentityError.keychain("copy key", status) }
        guard let attributes = result as? [CFString: Any],
            let applicationLabel = attributes[kSecAttrApplicationLabel] as? Data,
            let reference = attributes[kSecValueRef] as CFTypeRef?,
            CFGetTypeID(reference) == SecKeyGetTypeID()
        else { throw IdentityError.keychain("copy key", errSecInternalError) }
        return ((reference as! SecKey), applicationLabel)  // type id checked above
    }

    /// The certificates whose public key is `key`, found by public-key hash and re-checked by SPKI.
    private func copyCertificates(for key: (key: SecKey, applicationLabel: Data)) throws -> [SecCertificate] {
        var query = queries.certificates(publicKeyHash: key.applicationLabel)
        query[kSecReturnRef] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw IdentityError.keychain("copy certificates", status) }
        let references = (result as? [CFTypeRef]) ?? result.map { [$0] } ?? []
        let spki = try spkiSHA256(publicKey: key.key)
        return try references.map { reference in
            guard CFGetTypeID(reference) == SecCertificateGetTypeID() else {
                throw IdentityError.keychain("copy certificates", errSecInternalError)
            }
            let certificate = reference as! SecCertificate  // type id checked above
            // Defense in depth: never act on a certificate that isn't for our key, whatever the query returned.
            guard try spkiSHA256(certificate) == spki else {
                throw IdentityError.certificate("the Keychain returned a certificate for a different key")
            }
            return certificate
        }
    }

    /// The identity of the slot's key and its certificate. The query differs by keychain (``KeychainQueries``); the
    /// result is pinned to the certificate either way.
    private func copyIdentity(_ name: KeyName) throws -> SecIdentity? {
        guard let key = try copyKey(name), let certificate = try copyCertificates(for: key).last else {
            return nil
        }
        let query = queries.identity(certificate: certificate, applicationLabel: key.applicationLabel)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result else {
            throw IdentityError.keychain("copy identity", status == errSecSuccess ? errSecInternalError : status)
        }
        // One reference (kSecMatchLimitOne) or an array of them (kSecMatchLimitAll).
        let candidates = (result as? [CFTypeRef]) ?? [result]
        let expected = SecCertificateCopyData(certificate) as Data
        for candidate in candidates {
            guard CFGetTypeID(candidate) == SecIdentityGetTypeID() else {
                throw IdentityError.keychain("copy identity", errSecInternalError)
            }
            let identity = candidate as! SecIdentity  // type id checked above
            var paired: SecCertificate?
            if SecIdentityCopyCertificate(identity, &paired) == errSecSuccess, let paired,
                SecCertificateCopyData(paired) as Data == expected
            {
                return identity
            }
        }
        throw IdentityError.certificate("the Keychain returned an identity for a different certificate")
    }

    /// Deletes the slot's key and the certificates for it. Only items this store wrote can match: the key by its
    /// namespaced tag and label, the certificates by that key's public-key hash (checked before deleting).
    private func deleteItems(_ name: KeyName) throws {
        if let key = try copyKey(name), try !copyCertificates(for: key).isEmpty {
            try deleteAll(queries.certificates(publicKeyHash: key.applicationLabel), "delete certificates")
        }
        try deleteAll(queries.key(name), "delete key")
    }

    private func deleteAll(_ query: [CFString: Any], _ operation: String) throws {
        // The file keychain has deleted only the first match on some releases; loop until nothing is left.
        for _ in 0..<8 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw IdentityError.keychain(operation, status) }
        }
    }

    /// Moves a key to another slot. Its certificate follows by public-key hash, so it needs no update.
    private func relabel(_ name: KeyName, to target: KeyName) throws {
        let changes: [CFString: Any] = [kSecAttrLabel: target.label]
        let status = SecItemUpdate(queries.key(name) as CFDictionary, changes as CFDictionary)
        guard status == errSecSuccess else { throw IdentityError.keychain("relabel key", status) }
    }
}

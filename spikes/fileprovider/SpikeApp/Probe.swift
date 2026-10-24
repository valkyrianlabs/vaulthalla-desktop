// THROWAWAY SPIKE: which identity queries does the data protection keychain answer for an SE key + certificate?
import Foundation
import Security
import VHIdentity

func probeIdentity() throws {
    let tag = Data("sh.vaulthalla.desktop.spike.probe".utf8)
    var error: Unmanaged<CFError>?
    let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error)!
    let attrs: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
        kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
        kSecUseDataProtectionKeychain: true, kSecAttrAccessGroup: Spike.keychainGroup,
        kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: tag, kSecAttrLabel: "probe",
                              kSecAttrAccessControl: access] as [CFString: Any],
    ]
    guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else { throw SpikeError("keygen \(error!.takeRetainedValue())") }
    let keyAttrs = SecKeyCopyAttributes(key) as! [CFString: Any]
    let klbl = keyAttrs[kSecAttrApplicationLabel] as! Data
    Spike.log("probe: SE key klbl=\(klbl.hex) tkid=\(keyAttrs[kSecAttrTokenID] ?? "-")")
    let der = try DeviceCertificate.make(privateKey: key, commonName: "Vaulthalla Desktop probe")
    let cert = SecCertificateCreateWithData(nil, der as CFData)!
    var add: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecValueRef: cert, kSecUseDataProtectionKeychain: true,
                                kSecAttrAccessGroup: Spike.keychainGroup, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                kSecReturnAttributes: true]
    var added: CFTypeRef?
    Spike.log("probe: add cert \(Spike.describe(SecItemAdd(add as CFDictionary, &added)))")
    let certAttrs = added as? [CFString: Any] ?? [:]
    Spike.log("probe: cert pkhh=\((certAttrs[kSecAttrPublicKeyHash] as? Data)?.hex ?? "nil") agrp=\(certAttrs[kSecAttrAccessGroup] ?? "-")")
    add = [:]

    func tryQuery(_ name: String, _ extra: [CFString: Any]) {
        var q: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecUseDataProtectionKeychain: true]
        q.merge(extra) { $1 }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        var detail = ""
        if status == errSecSuccess, let r = result {
            if CFGetTypeID(r) == SecIdentityGetTypeID() {
                var c: SecCertificate?; SecIdentityCopyCertificate(r as! SecIdentity, &c)
                detail = " -> identity, cert matches=\(c.map { SecCertificateCopyData($0) as Data == der } ?? false)"
            } else if let arr = r as? [Any] { detail = " -> \(arr.count) results" }
        }
        Spike.log("probe: identity query [\(name)]: \(Spike.describe(status))\(detail)")
    }
    tryQuery("matchItemList+group+one", [kSecMatchItemList: [cert], kSecAttrAccessGroup: Spike.keychainGroup, kSecMatchLimit: kSecMatchLimitOne])
    tryQuery("matchItemList", [kSecMatchItemList: [cert]])
    tryQuery("pkhh+group+one", [kSecAttrPublicKeyHash: klbl, kSecAttrAccessGroup: Spike.keychainGroup, kSecMatchLimit: kSecMatchLimitOne])
    tryQuery("pkhh", [kSecAttrPublicKeyHash: klbl])
    tryQuery("klbl(applicationLabel)", [kSecAttrApplicationLabel: klbl])
    tryQuery("tag", [kSecAttrApplicationTag: tag])
    tryQuery("group all", [kSecAttrAccessGroup: Spike.keychainGroup, kSecMatchLimit: kSecMatchLimitAll])
    tryQuery("all", [kSecMatchLimit: kSecMatchLimitAll])
    var ident: SecIdentity?
    Spike.log("probe: SecIdentityCreateWithCertificate(nil): \(Spike.describe(SecIdentityCreateWithCertificate(nil, cert, &ident)))")

    // clean up
    let delCert: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecUseDataProtectionKeychain: true, kSecAttrPublicKeyHash: klbl]
    let delKey: [CFString: Any] = [kSecClass: kSecClassKey, kSecUseDataProtectionKeychain: true, kSecAttrApplicationTag: tag]
    Spike.log("probe: cleanup cert \(Spike.describe(SecItemDelete(delCert as CFDictionary))) key \(Spike.describe(SecItemDelete(delKey as CFDictionary)))")
}

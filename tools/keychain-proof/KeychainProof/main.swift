// Signed-build proof for DeviceIdentityStore in the data protection keychain (valkyrianlabs/vaulthalla-desktop#11). Run it with
// tools/keychain-proof/run.sh, never from CI: it needs a team-signed app with keychain-access-groups.
//
// Every item it writes is under a namespace unique to the run (sh.vaulthalla.app.proof.<uuid>), and all of them
// are deleted before it exits, also when a step fails. The exit code is 0 only if every check passed and nothing was
// left behind.
//
// Arguments: the keychain access group to also run with explicitly (`<TEAM>.<bundle id>`); without it only the
// default group (what DeviceKeys.standard() uses) is exercised.

import Foundation
import Security
import VHIdentity

// Top-level code in main.swift runs on the main actor; everything below is main-actor isolated with it.
let namespace = "sh.vaulthalla.app.proof.\(UUID().uuidString.lowercased())"
let nodeTags = ["node-se", "node-sw"]
var failures = 0
/// Public-key hashes of every key the run created, to prove afterwards that no key or certificate is left.
var createdLabels: [Data] = []

@MainActor func log(_ line: String) { print(line); fflush(stdout) }

@MainActor func check(_ condition: Bool, _ what: String) {
    if condition { log("  ok    \(what)") } else { failures += 1; log("  FAIL  \(what)") }
}

@MainActor func status(_ code: OSStatus) -> String {
    "\(code) (\((SecCopyErrorMessageString(code, nil) as String?) ?? "?"))"
}

@MainActor func applicationLabel(_ identity: DeviceIdentity) -> Data? {
    (SecKeyCopyAttributes(identity.privateKey) as? [CFString: Any])?[kSecAttrApplicationLabel] as? Data
}

@MainActor func record(_ identity: DeviceIdentity) {
    if let label = applicationLabel(identity), !createdLabels.contains(label) { createdLabels.append(label) }
}

@MainActor func signs(_ identity: DeviceIdentity) -> Bool {
    let message = Data("vaulthalla keychain proof".utf8)
    guard
        let signature = SecKeyCreateSignature(
            identity.privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, nil),
        let publicKey = SecCertificateCopyKey(identity.certificate)
    else { return false }
    return SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature, nil)
}

/// The identity queries the store used before the fix, and the one it uses now, against a real identity. Reported,
/// not asserted: they document the keychain behavior the fix depends on.
@MainActor func probeIdentityQueries(_ identity: DeviceIdentity, group: String?) {
    guard let label = applicationLabel(identity) else { return log("  FAIL  no application label"); }
    func query(_ name: String, _ extra: [CFString: Any]) {
        var query: [CFString: Any] = [
            kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecUseDataProtectionKeychain: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        if let group { query[kSecAttrAccessGroup] = group }
        query.merge(extra) { $1 }
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        log("  info  identity query by \(name): \(status(code))")
    }
    query("kSecMatchItemList (before the fix)", [kSecMatchItemList: [identity.certificate]])
    query("kSecAttrPublicKeyHash", [kSecAttrPublicKeyHash: label])
    query("kSecAttrApplicationLabel (the fix)", [kSecAttrApplicationLabel: label])
}

@MainActor func run(group: String?) async {
    let groupName = group ?? "default group"
    log("== data protection keychain, \(groupName), namespace \(namespace)")
    createdLabels = []
    let store = DeviceIdentityStore(configuration: .init(namespace: namespace, accessGroup: group))
    do {
        check(try await store.identity(for: "node-se") == nil, "no identity before create")

        // Create, then find again, a Secure Enclave identity: what pairing does (DeviceKeys.identityForPairing).
        let created = try await store.createIdentity(for: "node-se", deviceName: "Keychain Proof", backend: .secureEnclave)
        record(created)
        check(created.backend == .secureEnclave, "create: Secure Enclave identity \(created.deviceID.prefix(12))…")
        probeIdentityQueries(created, group: group)
        let found = try await store.identity(for: "node-se")
        check(found?.spkiSHA256 == created.spkiSHA256, "find: same key")
        check(found?.certificateDER == created.certificateDER, "find: same certificate")
        check(found?.backend == .secureEnclave, "find: Secure Enclave backend")
        check(found.map(signs) == true, "the found identity's key signs; its certificate's key verifies")
        await expectThrows(IdentityError.alreadyExists(nodeTag: "node-se"), "create again refuses") {
            _ = try await store.createIdentity(for: "node-se", deviceName: "Keychain Proof", backend: .secureEnclave)
        }

        // Rotate: pending replacement, retry reuses it, complete swaps it in.
        let server = Data(repeating: 0xA5, count: 32)
        let rotation = try await store.rotate(for: "node-se", serverSPKISHA256: server)
        record(rotation.replacement)
        check(rotation.replacement.backend == .secureEnclave, "rotate: Secure Enclave replacement")
        check(rotation.replacement.spkiSHA256 != created.spkiSHA256, "rotate: new key")
        if let oldPublic = SecKeyCopyPublicKey(created.privateKey) {
            check(rotation.proof.isValid(oldPublicKey: oldPublic, serverSPKISHA256: server), "rotate: proof verifies")
        }
        check(try await store.pendingRotation(for: "node-se")?.spkiSHA256 == rotation.replacement.spkiSHA256,
              "rotate: pending replacement found")
        check(try await store.identity(for: "node-se")?.spkiSHA256 == created.spkiSHA256,
              "rotate: current identity unchanged until completed")
        let retry = try await store.rotate(for: "node-se", serverSPKISHA256: server)
        check(retry.replacement.spkiSHA256 == rotation.replacement.spkiSHA256, "rotate: a retry reuses the replacement")
        let completed = try await store.completeRotation(for: "node-se")
        check(completed.spkiSHA256 == rotation.replacement.spkiSHA256, "complete: replacement is current")
        check(try await store.identity(for: "node-se")?.spkiSHA256 == rotation.replacement.spkiSHA256,
              "complete: found as the current identity")
        check(try await store.pendingRotation(for: "node-se") == nil, "complete: nothing pending")
        check(!hasCertificate(publicKeyHash: applicationLabel(created), group: group), "complete: old certificate gone")

        // Cancel discards a pending replacement.
        let second = try await store.rotate(for: "node-se", serverSPKISHA256: server)
        record(second.replacement)
        try await store.cancelRotation(for: "node-se")
        check(try await store.pendingRotation(for: "node-se") == nil, "cancel: nothing pending")
        check(try await store.identity(for: "node-se")?.spkiSHA256 == completed.spkiSHA256, "cancel: current kept")
        check(!hasCertificate(publicKeyHash: applicationLabel(second.replacement), group: group),
              "cancel: replacement certificate gone")

        // A software key in the same keychain (the store supports it; DeviceKeys doesn't create one there).
        let software = try await store.createIdentity(for: "node-sw", deviceName: "Keychain Proof", backend: .software)
        record(software)
        check(try await store.identity(for: "node-sw")?.spkiSHA256 == software.spkiSHA256, "software key: found")
        check(try await store.identity(for: "node-se")?.spkiSHA256 == completed.spkiSHA256,
              "software key: the Secure Enclave identity is independent")

        // Delete.
        try await store.deleteIdentity(for: "node-se")
        check(try await store.identity(for: "node-se") == nil, "delete: identity gone")
        check(try await store.identity(for: "node-sw") != nil, "delete: other node kept")
        try await store.deleteIdentity(for: "node-se")
        check(true, "delete: deleting again succeeds")
    } catch {
        failures += 1
        log("  FAIL  \(error)")
    }
    await cleanUp(store, group: group)
}

@MainActor func hasCertificate(publicKeyHash: Data?, group: String?) -> Bool {
    guard let publicKeyHash else { return true }
    var query: [CFString: Any] = [
        kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: publicKeyHash, kSecUseDataProtectionKeychain: true,
    ]
    if let group { query[kSecAttrAccessGroup] = group }
    return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
}

@MainActor func hasKey(tag: String, group: String?) -> Bool {
    var query: [CFString: Any] = [
        kSecClass: kSecClassKey, kSecAttrApplicationTag: Data(tag.utf8), kSecUseDataProtectionKeychain: true,
    ]
    if let group { query[kSecAttrAccessGroup] = group }
    return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
}

/// Deletes everything under the run's namespace through the store, then proves with direct queries (by the
/// namespaced tags and by the public-key hash of every key created) that nothing is left.
@MainActor func cleanUp(_ store: DeviceIdentityStore, group: String?) async {
    for tag in nodeTags {
        do {
            try await store.deleteIdentity(for: tag)
        } catch {
            failures += 1
            log("  FAIL  cleanup \(tag): \(error)")
        }
    }
    let leftovers = nodeTags.filter { hasKey(tag: "\(namespace)/\($0)", group: group) }
        + createdLabels.filter { hasCertificate(publicKeyHash: $0, group: group) }.map { _ in "certificate" }
    check(leftovers.isEmpty, "cleanup: no key or certificate left (\(createdLabels.count) keys created)")
}

/// `#expect(throws:)` for this plain executable.
@MainActor func expectThrows(
    _ expected: IdentityError, _ what: String, _ body: () async throws -> Void
) async {
    do {
        try await body()
        check(false, "\(what): no error")
    } catch let error as IdentityError {
        check(error == expected, "\(what) (\(error))")
    } catch {
        check(false, "\(what): \(error)")
    }
}

/// How many keys and certificates the access group holds (counts only; nothing about them is read). Zero after a
/// run proves the cleanup when the group is used by nothing else, such as a group of its own for the proof.
@MainActor func countItems(group: String) -> (keys: Int, certificates: Int) {
    func count(_ itemClass: CFString) -> Int {
        let query: [CFString: Any] = [
            kSecClass: itemClass, kSecAttrAccessGroup: group, kSecUseDataProtectionKeychain: true,
            kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return 0 }
        return (result as? [CFTypeRef])?.count ?? 1
    }
    return (count(kSecClassKey), count(kSecClassCertificate))
}

// MARK: Main

let explicitGroup = CommandLine.arguments.dropFirst().first
await run(group: nil)
if let explicitGroup {
    await run(group: explicitGroup)
    let left = countItems(group: explicitGroup)
    log("info  \(explicitGroup) now holds \(left.keys) key(s) and \(left.certificates) certificate(s)")
}
log(failures == 0 ? "PASS: keychain proof" : "FAIL: \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)

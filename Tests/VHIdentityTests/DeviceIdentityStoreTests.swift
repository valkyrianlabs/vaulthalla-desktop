import Foundation
import Security
import Testing
import VHIdentity

/// Store tests run against the file-based login keychain under a namespace unique to the run, and delete what they
/// create (``TestKeychain/withStore(keychain:_:)``). Software keys only: no Secure Enclave, no access control, so
/// nothing can prompt.
@Suite(.serialized) struct DeviceIdentityStoreTests {
    @Test func lifecycle() async throws {
        try await TestKeychain.withStore { store in
            #expect(try await store.identity(for: "node-a") == nil)

            let created = try await store.createIdentity(for: "node-a", deviceName: "Test Mac", backend: .software)
            #expect(created.backend == .software)
            #expect(created.deviceName == "Test Mac")
            #expect(created.deviceID.count == 64)
            #expect(created.spkiSHA256 == (try spkiSHA256(publicKey: created.privateKey)))
            #expect(created.spkiSHA256 == (try spkiSHA256(created.certificate)))
            #expect(SecCertificateCreateWithData(nil, created.certificateDER as CFData) != nil)
            #expect("\(created)" == "DeviceIdentity(node: node-a, backend: software, device: \(created.deviceID))")

            let fetched = try #require(try await store.identity(for: "node-a"))
            #expect(fetched.spkiSHA256 == created.spkiSHA256)
            #expect(fetched.certificateDER == created.certificateDER)

            // A second identity for another node is independent.
            let other = try await store.createIdentity(for: "node-b", deviceName: "Test Mac", backend: .software)
            #expect(other.spkiSHA256 != created.spkiSHA256)

            // The identity's key signs; the certificate's key verifies.
            let message = Data("hello".utf8)
            let signature = try #require(
                SecKeyCreateSignature(fetched.privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, nil))
            let certificateKey = try #require(SecCertificateCopyKey(fetched.certificate))
            #expect(SecKeyVerifySignature(certificateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature, nil))

            let hash = try publicKeyHash(created.privateKey)
            try await store.deleteIdentity(for: "node-a")
            #expect(try await store.identity(for: "node-a") == nil)
            #expect(try await store.identity(for: "node-b") != nil)
            let namespace = await store.configuration.namespace
            #expect(!TestKeychain.hasLeftovers(applicationTag: "\(namespace)/node-a", publicKeyHash: hash))
            // Deleting again is fine.
            try await store.deleteIdentity(for: "node-a")
        }
    }

    @Test func refusesToReplaceAnIdentity() async throws {
        try await TestKeychain.withStore { store in
            _ = try await store.createIdentity(for: "node-a", deviceName: "Test Mac", backend: .software)
            await #expect(throws: IdentityError.alreadyExists(nodeTag: "node-a")) {
                try await store.createIdentity(for: "node-a", deviceName: "Test Mac", backend: .software)
            }
        }
    }

    @Test(arguments: ["", "a/b", "a#next", "tag with space", "é", String(repeating: "x", count: 129)])
    func rejectsUnsafeNodeTags(_ tag: String) async throws {
        try await TestKeychain.withStore { store in
            await #expect(throws: IdentityError.invalidNodeTag(tag)) {
                try await store.createIdentity(for: tag, deviceName: "Test Mac", backend: .software)
            }
        }
    }

    @Test func rotation() async throws {
        try await TestKeychain.withStore { store in
            let server = Data.counting(from: 0x00)
            let original = try await store.createIdentity(for: "node-a", deviceName: "Test Mac", backend: .software)
            #expect(try await store.pendingRotation(for: "node-a") == nil)

            let rotation = try await store.rotate(for: "node-a", serverSPKISHA256: server)
            #expect(rotation.current.spkiSHA256 == original.spkiSHA256)
            #expect(rotation.replacement.spkiSHA256 != original.spkiSHA256)
            #expect(rotation.replacement.deviceName == "Test Mac")
            #expect(rotation.proof.newSPKISHA256 == rotation.replacement.spkiSHA256)
            let oldPublic = try #require(SecKeyCopyPublicKey(original.privateKey))
            #expect(rotation.proof.isValid(oldPublicKey: oldPublic, serverSPKISHA256: server))

            // Until completed, the node still sees the original identity.
            #expect(try await store.identity(for: "node-a")?.spkiSHA256 == original.spkiSHA256)

            // A retry reuses the pending replacement.
            let retry = try await store.rotate(for: "node-a", serverSPKISHA256: server)
            #expect(retry.replacement.spkiSHA256 == rotation.replacement.spkiSHA256)

            let completed = try await store.completeRotation(for: "node-a")
            #expect(completed.spkiSHA256 == rotation.replacement.spkiSHA256)
            #expect(try await store.identity(for: "node-a")?.spkiSHA256 == rotation.replacement.spkiSHA256)
            #expect(try await store.pendingRotation(for: "node-a") == nil)
            let namespace = await store.configuration.namespace
            #expect(
                !TestKeychain.hasLeftovers(
                    applicationTag: "\(namespace)/node-a#next", publicKeyHash: try publicKeyHash(original.privateKey)))

            // Cancel discards a pending replacement and keeps the current identity.
            let second = try await store.rotate(for: "node-a", serverSPKISHA256: server, deviceName: "Renamed Mac")
            #expect(second.replacement.deviceName == "Renamed Mac")
            try await store.cancelRotation(for: "node-a")
            #expect(try await store.pendingRotation(for: "node-a") == nil)
            #expect(try await store.identity(for: "node-a")?.spkiSHA256 == completed.spkiSHA256)
            await #expect(throws: IdentityError.noPendingRotation(nodeTag: "node-a")) {
                try await store.completeRotation(for: "node-a")
            }
        }
    }

    @Test func rotateWithoutIdentityFails() async throws {
        try await TestKeychain.withStore { store in
            await #expect(throws: IdentityError.notFound(nodeTag: "node-a")) {
                try await store.rotate(for: "node-a", serverSPKISHA256: Data.counting(from: 0))
            }
        }
    }

    /// The data protection keychain refuses unsigned processes; the store must say so instead of failing obscurely.
    @Test(.disabled(if: TestKeychain.dataProtectionKeychainAvailable, "this process is entitled"))
    func dataProtectionNeedsEntitlement() async throws {
        try await TestKeychain.withStore(keychain: .dataProtection) { store in
            let error = await #expect(throws: IdentityError.self) {
                try await store.createIdentity(for: "node-a", deviceName: "Test Mac", backend: .software)
            }
            guard case .missingEntitlement = error else {
                Issue.record("expected missingEntitlement, got \(String(describing: error))")
                return
            }
        }
    }

    /// Runs only in a signed host with a keychain access group (the app's test plan); skipped under `swift test`.
    @Test(.enabled(if: TestKeychain.dataProtectionKeychainAvailable, "needs keychain entitlements (signed app)"))
    func secureEnclaveIdentity() async throws {
        try await TestKeychain.withStore(keychain: .dataProtection) { store in
            let identity = try await store.createIdentity(
                for: "node-a", deviceName: "Test Mac", backend: .secureEnclave)
            #expect(identity.backend == .secureEnclave)
            let fetched = try #require(try await store.identity(for: "node-a"))
            #expect(fetched.backend == .secureEnclave)
            #expect(fetched.spkiSHA256 == identity.spkiSHA256)
            let rotation = try await store.rotate(for: "node-a", serverSPKISHA256: Data.counting(from: 0))
            #expect(rotation.replacement.backend == .secureEnclave)
            try await store.completeRotation(for: "node-a")
        }
    }
}

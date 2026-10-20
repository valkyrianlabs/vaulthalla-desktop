import Foundation
import Network
import Security
import Synchronization
import Testing
import VHContract
import VHCore
@testable import VHTransport

/// The last value a callback reported, readable from the test.
final class Recorded<Value: Sendable>: Sendable {
    private let state = Mutex<Value?>(nil)
    var value: Value? { state.withLock { $0 } }
    func record(_ value: Value?) { state.withLock { $0 = value } }
}

/// The `.mutualTLS` path end to end against a TLS 1.3 loopback server that requires a client certificate. The
/// identities are throwaway self-signed P-256 certificates, imported in memory (never into a keychain).
@Suite struct WsClientTLSTests {
    // openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 ...; openssl pkcs12 -export (password "test")
    static let serverP12 = """
        MIIEFAIBAzCCA8IGCSqGSIb3DQEHAaCCA7MEggOvMIIDqzCCAloGCSqGSIb3DQEHBqCCAkswggJHAgEAMIICQAYJKoZIhvcNAQcBMF8G
        CSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBBc98Q+uErXM4vydJ+SqsPvAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQ
        XShOl8ijWCC6yBTUs42Wq4CCAdByI6eYpKAJ3eJ6dy/NTFh6hIcvzwo8hoIX1CU2JyxL3to6hlNtrUHQbSQv5nWwCXKupuWdHOscCbJy
        JDmwr8yFRUSCiK+M0xMY/IGyhV+OwFQXFqxbriUL9olalUWKHqUkct8AnlMTi6icGFy6XkcyP5rFLbMZSmfjM0/qw5q8GRet5Lcxctcx
        cTQr1Scg7yYV9N/UTHbFgn2pYPi3AaF76cWasAgYjZXrcl7Qk3+TCkpClLpHgbaBAnr538M+85KfONVXzqPe2tXXje77XknujuS4fKE3
        QEyD1/qte8OgEbEvawqaI9G1Qi08txOrBSpdhehelr5XlG9vwaY+yinIyhFWBKw+i9y/IlSUu6L2CE+fwLMoXq3tsA7Qa1oZPEaC4cGl
        8nLngg+FhnyaoaXooWhsUb25cU9rIOH2Pk3DbFhsmCrwCSNvMF644qwQ47JcH1Y3iUuFvd/JWFUJLEG3ac+xgAIW3afl9YXkMe5oZ0+v
        ge9wkiYvfvLssLOpKdxxgKwH/nHTy/Ga1oWznKftwq6UnQ60P5ls6+Q1FOch8z6O0ZAPPl0vs21iUdzkrt3mV95LyMqsR4X0wWyE1lEN
        OWk8a6YqgcDq7z4ySItxzDCCAUkGCSqGSIb3DQEHAaCCAToEggE2MIIBMjCCAS4GCyqGSIb3DQEMCgECoIH3MIH0MF8GCSqGSIb3DQEF
        DTBSMDEGCSqGSIb3DQEFDDAkBBCrE4I5Gddw/UdyXot6TruHAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQ/E+c7Cw8I+NI
        GLS0PRR0zASBkLKoCbQpVmzcecg70NCKvEkDqtEzTZ7rf633S8R4ZDX6SJiBUuixcmYQnJJZX1IpizsQnIdvD9N5qN9hcgYQDpmf11w+
        1bV8GHsaaaAhvwUeFuLqYdETpnC7HonTvYeXVCwXGLknbc/0/qWrTRQ3Mhpea9sKMSAGV/rIttpS5Uhv4pcQ1vjYzZU/ZVG7CemqETEl
        MCMGCSqGSIb3DQEJFTEWBBQBkmq2+LXRoMsLxSI/yzB4Fjse+DBJMDEwDQYJYIZIAWUDBAIBBQAEIOh9pvXiOyTm7h3r8KjSZbI9WMCg
        nC85w5r6VLIod+QpBBBjQ+bQ0iRNI7Uekl9MgDksAgIIAA==
        """
    static let clientP12 = """
        MIIEFAIBAzCCA8IGCSqGSIb3DQEHAaCCA7MEggOvMIIDqzCCAloGCSqGSIb3DQEHBqCCAkswggJHAgEAMIICQAYJKoZIhvcNAQcBMF8G
        CSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBCq4jwSHgBD6RimXJshBq9MAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQ
        QFhkpeSsbe/P/byy3LEARoCCAdC8JYhXjiwoZusCdgC913dn5Yu85qk48jYnI/HGGZmqCyDiiAYlXTJXrltQ0YiR/tomlExbUUMhXtCL
        dW97Z5g0YZFMEW7MEUltGbm39nYHVUItoUjH3x8ccNCFDmcPgjPUCqIaThCRU9ePkLhCO/x6Vg2wlOsG2JhNCORFDgCSzx32qPGbOoam
        DDEdqWjPpsj3WtuzOi+GxpEWvF21drrNt0E8snnB9pgynhiTr0U32vSrDW4MeFcKWLNFNCayxWN7gcyKlz2pjjCQPFqX/dlhAnKD9RK7
        cYCZu9QEg0cJVMAzeRlrUpbaaRya/5APblI/88APZGglgCuc0n4Km8H+MDNuG8oaDobuI+YQSHl8Y9Oq5IUwcsLvGY/pbTJ7Sc4rA/ES
        /0nZLP2hgtKM4BKIiH+MvbS8IosPp8mQovo+bkVSlkDo8l2c4s0+T6DJy3p+jYesqXveO41BuK0sRvg/kj3ZkedRdDvYhw88q40OQN6j
        /7yMydILmQiBJ91VlIYSekarea7opxg25vWkZwot0F3yAeUeoKDo/op38Vnnxl9jnOTRwK/iXl4zzVXn09KdJ2lOhc2Az1KATAFgEtNd
        jXiHiotm5fKTAb4vuF24XTCCAUkGCSqGSIb3DQEHAaCCAToEggE2MIIBMjCCAS4GCyqGSIb3DQEMCgECoIH3MIH0MF8GCSqGSIb3DQEF
        DTBSMDEGCSqGSIb3DQEFDDAkBBAad9g4PPkfjK4XrJRXP2FSAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQu75D4XpE0/6R
        QmK2slI2sQSBkDiaf5cUeImEnvwbn6u9D/m33fe/PLANeU3IJdmsPG8frVAMIXvKUD4bg1ltU+VrvFtBB7qpbr8z5boVKmdRbE+ghrxa
        QQchbLcH5BYetuvCvGJ3hu1iRaE/kBfzlffemkRMaPypqoMxdD+jfqui0aEGuOfo3u5iv0M6E6DgbcQmtSK0vbLAY0Ux6yI9N5tIEjEl
        MCMGCSqGSIb3DQEJFTEWBBST6PCmWexGDkZQvTmTWsa4Z3K3lTBJMDEwDQYJYIZIAWUDBAIBBQAEIFVTXYmCeCal6E9LC7pc5FuYObJF
        8ttMogygs4Ges6pPBBDxMAdV/6mekZ5Jv4qWSDXVAgIIAA==
        """
    static let serverSPKI = "45a88c7a322a3c2986483f29e4a91414aa16866e77b200cd699fb3d5c12bd723"
    static let clientSPKI = "35837a3e8eb9545e3e2b6fef0e98afaf5cef042c0001e86f5151c16540b5235a"

    private static func identity(_ base64: String) throws -> SecIdentity {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let options: [String: Any] = [kSecImportExportPassphrase as String: "test",
                                      kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        try #require(SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess)
        let first = try #require((items as? [[String: Any]])?.first)
        return try #require(first[kSecImportItemIdentity as String].map { $0 as! SecIdentity })
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func data(hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })
    }

    /// TLS 1.3 server options that require a client certificate and record its SPKI hash.
    private static func serverTLS(clientSPKI: Recorded<String>) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_local_identity(security, sec_identity_create(try identity(serverP12))!)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            clientSPKI.record(leaf.flatMap(CertificateSPKI.sha256(of:)).map(hex))
            complete(true)
        }, DispatchQueue.global())
        return options
    }

    private static func client(port: UInt16, pin: Data?, observed: Recorded<Data>) throws -> WsClient {
        let identity = try identity(clientP12)
        return try WsClient(configuration: .init(
            endpoint: NodeEndpoint(host: "127.0.0.1", port: port),
            security: .mutualTLS(identity: identity, serverSPKIPin: pin, onServerSPKI: { spki in
                observed.record(spki)
            }),
            reconnect: ReconnectPolicy(base: .milliseconds(20), cap: .milliseconds(80)),
            connectTimeout: .seconds(2)
        ))
    }

    @Test(arguments: [false, true])
    func trustsOnFirstUseOrByPin(pinned: Bool) async throws {
        let clientSPKI = Recorded<String>()
        let server = try await TestServer.start(tls: try Self.serverTLS(clientSPKI: clientSPKI))
        defer { server.stop() }
        let observed = Recorded<Data>()
        let ws = try Self.client(port: server.port, pin: pinned ? Self.data(hex: Self.serverSPKI) : nil,
                                 observed: observed)

        let reply = Task { try await ws.send(command: "meta.contract.get", payload: .null) }
        try #require(await server.next()).ok(["ws_hash": "h"])
        #expect(try await reply.value == ["ws_hash": "h"])
        // Pairing sees the server's SPKI; a pinned connection doesn't need to report it.
        #expect(observed.value.map(Self.hex) == (pinned ? nil : Self.serverSPKI))
        #expect(clientSPKI.value == Self.clientSPKI)
        await ws.close()
    }

    @Test func refusesAServerThatDoesNotMatchThePin() async throws {
        let server = try await TestServer.start(tls: try Self.serverTLS(clientSPKI: Recorded()))
        defer { server.stop() }
        let ws = try Self.client(port: server.port, pin: Data(repeating: 0xAB, count: 32), observed: Recorded())
        let states = await ws.states()

        await #expect(throws: WsError.disconnected) {
            try await ws.send(command: "meta.contract.get", payload: .null)
        }
        var failure: String?
        for await state in states {
            if case .failed(let reason) = state { failure = reason; break }
        }
        #expect(failure?.contains(Self.serverSPKI) == true)
        #expect(await server.next(within: .milliseconds(50)) == nil)
    }
}

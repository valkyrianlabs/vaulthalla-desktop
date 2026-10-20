import Foundation
import Network
import Security
import Synchronization
import Testing
import VHIdentity

/// A real TLS 1.3 handshake on loopback between an `NWListener` (server identity) and an `NWConnection` (device
/// identity), each side pinning the other's SPKI the way docs/pairing.md §2 prescribes. Proves a Keychain identity
/// from `DeviceIdentityStore` works as a TLS client certificate end to end.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MutualTLSTests {
    @Test func handshakeWithPinnedIdentities() async throws {
        try await TestKeychain.withStore { store in
            let server = try await store.createIdentity(for: "server", deviceName: "Server", backend: .software)
            let client = try await store.createIdentity(for: "client", deviceName: "Client", backend: .software)

            let echo = try await EchoServer.start(identity: server, acceptedClientSPKI: client.spkiSHA256)
            defer { echo.stop() }
            let outcome = try await connect(port: echo.port, identity: client, pinnedServerSPKI: server.spkiSHA256)

            #expect(outcome.tlsVersion == .TLSv13)
            #expect(outcome.reply == Data("ping".utf8))
            #expect(echo.seenClientSPKIs == [client.spkiSHA256])
        }
    }

    @Test func serverRefusesUnknownDevice() async throws {
        try await TestKeychain.withStore { store in
            let server = try await store.createIdentity(for: "server", deviceName: "Server", backend: .software)
            let client = try await store.createIdentity(for: "client", deviceName: "Client", backend: .software)
            let stranger = try await store.createIdentity(for: "stranger", deviceName: "Stranger", backend: .software)

            let echo = try await EchoServer.start(identity: server, acceptedClientSPKI: client.spkiSHA256)
            defer { echo.stop() }
            await #expect(throws: (any Error).self) {
                try await connect(port: echo.port, identity: stranger, pinnedServerSPKI: server.spkiSHA256)
            }
            #expect(echo.seenClientSPKIs == [stranger.spkiSHA256])
        }
    }

    @Test func clientRefusesUnpinnedServer() async throws {
        try await TestKeychain.withStore { store in
            let server = try await store.createIdentity(for: "server", deviceName: "Server", backend: .software)
            let client = try await store.createIdentity(for: "client", deviceName: "Client", backend: .software)

            let echo = try await EchoServer.start(identity: server, acceptedClientSPKI: client.spkiSHA256)
            defer { echo.stop() }
            await #expect(throws: (any Error).self) {
                try await connect(port: echo.port, identity: client, pinnedServerSPKI: client.spkiSHA256)
            }
        }
    }
}

// MARK: - Harness

private let queue = DispatchQueue(label: "sh.vaulthalla.desktop.test.mtls")

/// TLS 1.3 only, with our identity and a verify block that accepts exactly one peer SPKI.
private func tlsOptions(
    identity: DeviceIdentity, peerSPKI: Data, requirePeerCertificate: Bool, onPeer: @escaping @Sendable (Data) -> Void
) throws -> NWProtocolTLS.Options {
    let options = NWProtocolTLS.Options()
    let security = options.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
    let localIdentity = try #require(sec_identity_create(identity.secIdentity))
    sec_protocol_options_set_local_identity(security, localIdentity)
    if requirePeerCertificate { sec_protocol_options_set_peer_authentication_required(security, true) }
    sec_protocol_options_set_verify_block(
        security,
        { _, trust, complete in
            // Trust is the pin, not a chain: take the leaf the peer presented and compare its SPKI hash.
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first,
                let spki = try? spkiSHA256(leaf)
            else { return complete(false) }
            onPeer(spki)
            complete(spki == peerSPKI)
        }, queue)
    return options
}

private final class EchoServer: Sendable {
    let listener: NWListener
    let port: NWEndpoint.Port
    private let log: SPKILog

    /// Every client SPKI the server's verify block saw, accepted or not.
    var seenClientSPKIs: [Data] { log.entries }

    private init(listener: NWListener, port: NWEndpoint.Port, log: SPKILog) {
        self.listener = listener
        self.port = port
        self.log = log
    }

    static func start(identity: DeviceIdentity, acceptedClientSPKI: Data) async throws -> EchoServer {
        let log = SPKILog()
        let tls = try tlsOptions(
            identity: identity, peerSPKI: acceptedClientSPKI, requirePeerCertificate: true, onPeer: log.append)
        let parameters = NWParameters(tls: tls)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port { once.run { continuation.resume(returning: port) } }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return EchoServer(listener: listener, port: port, log: log)
    }

    func stop() { listener.cancel() }
}

private final class SPKILog: Sendable {
    private let storage = Mutex<[Data]>([])
    var entries: [Data] { storage.withLock { $0 } }
    @Sendable func append(_ spki: Data) { storage.withLock { $0.append(spki) } }
}

private struct Outcome: Sendable {
    let tlsVersion: tls_protocol_version_t?
    let reply: Data?
}

/// Connects with `identity`, sends "ping", and returns the negotiated TLS version and the echoed reply.
private func connect(port: NWEndpoint.Port, identity: DeviceIdentity, pinnedServerSPKI: Data) async throws -> Outcome {
    let tls = try tlsOptions(
        identity: identity, peerSPKI: pinnedServerSPKI, requirePeerCertificate: false, onPeer: { _ in })
    let connection = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: tls))
    defer { connection.cancel() }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let once = Once()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: once.run { continuation.resume() }
            case .failed(let error), .waiting(let error): once.run { continuation.resume(throwing: error) }
            case .cancelled: once.run { continuation.resume(throwing: TestFailure("cancelled")) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
    let version = metadata.map { sec_protocol_metadata_get_negotiated_tls_protocol_version($0.securityProtocolMetadata) }

    let reply: Data? = try await withCheckedThrowingContinuation { continuation in
        connection.send(content: Data("ping".utf8), completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error); return }
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        })
    }
    return Outcome(tlsVersion: version, reply: reply)
}

/// Resumes a continuation at most once across racing Network.framework callbacks.
private final class Once: Sendable {
    private let done = Mutex(false)
    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

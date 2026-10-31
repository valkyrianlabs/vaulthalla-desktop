public import Foundation
public import Security
public import VHCore
import Network
import Synchronization
import os

/// What one probe of a candidate endpoint found (the server's transfer protocol §2, "Probing").
public struct EndpointProbeResult: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// The TLS 1.3 handshake finished and the server presented a pinned key.
        case ok
        /// Something answered and refused the connection (nothing listens on that port).
        case refused
        /// No answer within the probe's time (including networks with no route there).
        case timeout
        /// A TLS server answered with a key that isn't this node's: a different server lives there.
        case identityMismatch
        /// The TLS handshake failed for another reason.
        case tlsError(String)
        /// The host name didn't resolve.
        case unresolved
    }

    public var outcome: Outcome
    /// The round trip of the connection's handshake (TCP's, when the system reports it), for `ok`.
    public var rtt: Duration?
    /// The address actually connected to (a host name resolved), when known.
    public var remoteAddress: String?
    /// The local interface the connection used (`en0`, `utun4`, `lo0`), when known.
    public var interfaceName: String?
    /// Which of the probe's pins the server presented (`ok` only).
    public var matchedPin: Data?

    public init(outcome: Outcome, rtt: Duration? = nil, remoteAddress: String? = nil, interfaceName: String? = nil,
                matchedPin: Data? = nil) {
        self.outcome = outcome
        self.rtt = rtt
        self.remoteAddress = remoteAddress
        self.interfaceName = interfaceName
        self.matchedPin = matchedPin
    }
}

/// Probes one endpoint. ``TLSEndpointProber`` is the real one; tests stand in their own.
public protocol EndpointProbing: Sendable {
    func probe(_ endpoint: NodeEndpoint, timeout: Duration) async -> EndpointProbeResult
}

/// A probe is a TLS 1.3 handshake on a fresh connection, then close: the device identity as the client certificate
/// and the node's pins (current, then the announced next one) in place of trust evaluation, exactly as `WsClient`
/// connects (``TransportSecurity``). A TCP connect alone proves nothing, so it never counts as success.
///
/// Without an identity (before pairing, a `vaulthalla://pair` link), the handshake can't finish (the daemon requires a
/// client certificate), so the probe succeeds once the server's key passed the check: one of `pins`, or any key when
/// `pins` is empty.
public struct TLSEndpointProber: EndpointProbing {
    private let identity: IdentityBox?
    private let pins: [Data]

    public init(identity: SecIdentity?, pins: [Data]) {
        self.identity = identity.map(IdentityBox.init)
        self.pins = pins.filter { !$0.isEmpty }
    }

    public func probe(_ endpoint: NodeEndpoint, timeout: Duration) async -> EndpointProbeResult {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port), port.rawValue > 0, !endpoint.host.isEmpty else {
            return EndpointProbeResult(outcome: .unresolved)
        }
        let run = ProbeRun(pins: pins, requiresHandshake: identity != nil)
        let tls = TransportSecurity.probeOptions(identity: identity?.value, run: run)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int((timeout.components.seconds)))
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        return await withTaskCancellationHandler {
            await run.start(connection, timeout: timeout)
        } onCancel: {
            run.finish(EndpointProbeResult(outcome: .timeout))
        }
    }
}

/// One probe's state: the verify block and the connection's callbacks run on its queue, the answer is delivered once.
final class ProbeRun: Sendable {
    let pins: [Data]
    let requiresHandshake: Bool
    private let queue = DispatchQueue(label: "sh.vaulthalla.transport.probe")
    private let state = Mutex(State())
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "endpoints")

    private struct State {
        var started = ContinuousClock.now
        var verifiedAt: ContinuousClock.Instant?
        var matchedPin: Data?
        var mismatch = false
        var continuation: CheckedContinuation<EndpointProbeResult, Never>?
        var connection: NWConnection?
        var finished = false
        var early: EndpointProbeResult?
    }

    init(pins: [Data], requiresHandshake: Bool) {
        self.pins = pins
        self.requiresHandshake = requiresHandshake
    }

    var verifyQueue: DispatchQueue { queue }

    /// The verify block's decision for the server's SPKI.
    func verify(_ spki: Data) -> Bool {
        let matched: Data? = pins.isEmpty ? spki : pins.first { TransportSecurity.constantTimeEqual($0, spki) }
        state.withLock { state in
            if let matched {
                state.matchedPin = matched
                state.verifiedAt = .now
            } else {
                state.mismatch = true
            }
        }
        return matched != nil
    }

    func start(_ connection: NWConnection, timeout: Duration) async -> EndpointProbeResult {
        await withCheckedContinuation { continuation in
            let early = state.withLock { state -> EndpointProbeResult? in
                if let early = state.early { return early }
                state.continuation = continuation
                state.connection = connection
                state.started = .now
                return nil
            }
            if let early { return continuation.resume(returning: early) }
            connection.stateUpdateHandler = { [self] update in changed(update, connection) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.seconds(timeout)) { [self] in
                finish(EndpointProbeResult(outcome: .timeout))
            }
        }
    }

    private func changed(_ update: NWConnection.State, _ connection: NWConnection) {
        switch update {
        case .ready:
            let (verifiedAt, matched, started) = state.withLock { ($0.verifiedAt, $0.matchedPin, $0.started) }
            guard matched != nil else { return finish(EndpointProbeResult(outcome: .tlsError("no server key seen"))) }
            let fallback = (verifiedAt ?? .now) - started
            let path = connection.currentPath
            let address = path.flatMap { Self.address(of: $0.remoteEndpoint) }
            let interface = path?.availableInterfaces.first?.name
            connection.requestEstablishmentReport(queue: queue) { [self] report in
                let tcp = report?.handshakes.first { $0.definition == NWProtocolTCP.definition }
                let rtt = tcp.map { Duration.seconds($0.handshakeRTT) }.flatMap { $0 > .zero ? $0 : nil } ?? fallback
                finish(EndpointProbeResult(outcome: .ok, rtt: rtt, remoteAddress: address, interfaceName: interface,
                                           matchedPin: matched))
            }
        case .waiting(let error), .failed(let error):
            finish(failure(error, connection))
        case .cancelled:
            finish(EndpointProbeResult(outcome: .timeout))
        default:
            break
        }
    }

    /// What a failed or waiting connection means.
    private func failure(_ error: NWError, _ connection: NWConnection) -> EndpointProbeResult {
        let (verifiedAt, matched, mismatch, started) = state.withLock {
            ($0.verifiedAt, $0.matchedPin, $0.mismatch, $0.started)
        }
        if mismatch { return EndpointProbeResult(outcome: .identityMismatch) }
        if !requiresHandshake, let matched, let verifiedAt {
            // Without a client certificate the daemon ends the handshake after its key was checked: that's a pass.
            let address = connection.currentPath.flatMap { Self.address(of: $0.remoteEndpoint) }
            return EndpointProbeResult(outcome: .ok, rtt: verifiedAt - started, remoteAddress: address,
                                       interfaceName: connection.currentPath?.availableInterfaces.first?.name,
                                       matchedPin: matched)
        }
        switch error {
        case .dns:
            return EndpointProbeResult(outcome: .unresolved)
        case .posix(let code):
            switch code {
            case .ECONNREFUSED, .ECONNRESET: return EndpointProbeResult(outcome: .refused)
            default: return EndpointProbeResult(outcome: .timeout)
            }
        case .tls(let status):
            return EndpointProbeResult(outcome: .tlsError(Self.describe(status)))
        default:
            return EndpointProbeResult(outcome: .tlsError(error.debugDescription))
        }
    }

    /// Delivers `result` once and closes the connection.
    func finish(_ result: EndpointProbeResult) {
        let (continuation, connection) = state.withLock { state -> (CheckedContinuation<EndpointProbeResult, Never>?, NWConnection?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            if state.continuation == nil { state.early = result }
            defer { state.continuation = nil; state.connection = nil }
            return (state.continuation, state.connection)
        }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        continuation?.resume(returning: result)
    }

    static func address(of endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address):
            let text = "\(address)"
            return text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        if let text = SecCopyErrorMessageString(status, nil) as String? { return "\(text) (\(status))" }
        return "OSStatus \(status)"
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

extension TransportSecurity {
    /// TLS options for a probe: TLS 1.3, the identity (if any) as the client certificate, and `run`'s pin check in
    /// place of the system's trust evaluation.
    static func probeOptions(identity: SecIdentity?, run: ProbeRun) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        if let identity, let local = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(security, local)
        }
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
                  let spki = CertificateSPKI.sha256(of: leaf)
            else { return complete(false) }
            complete(run.verify(spki))
        }, run.verifyQueue)
        return options
    }

    /// Compares two hashes without an early exit.
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Classifies the address a connection reached (the server's transfer protocol §1.1 ranges, applied on the client):
/// loopback 127/8 and ::1; lan RFC 1918, IPv6 ULA fc00::/7 and link-local; vpn 100.64/10 and any address reached over
/// a tunnel interface (`utun*`, `ipsec*`, `ppp*`, `tun*`, `tailscale*`, `wg*`, `zt*`); wan any other address.
public enum EndpointClassifier {
    /// The class of `address` (an IP literal) reached over `interfaceName`; nil when `address` isn't an IP literal.
    public static func classify(address: String, interfaceName: String? = nil) -> EndpointClass? {
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        let byRange: EndpointClass
        if let v4 = IPv4Address(bare) {
            byRange = classify(v4: [UInt8](v4.rawValue))
        } else if let v6 = IPv6Address(bare) {
            byRange = classify(v6: [UInt8](v6.rawValue))
        } else {
            return nil
        }
        if byRange != .loopback, let interfaceName, isTunnel(interfaceName) { return .vpn }
        return byRange
    }

    /// Whether `name` is a tunnel interface: its traffic goes through a VPN whatever the address looks like.
    public static func isTunnel(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["utun", "ipsec", "ppp", "tun", "tap", "tailscale", "wg", "zt"].contains { lower.hasPrefix($0) }
    }

    /// The class a host is expected to have before anything is resolved: its own class for an IP literal,
    /// loopback for `localhost`, lan for `.local` and `.home.arpa` names; nil otherwise (decided by the connection).
    public static func estimate(host: String) -> EndpointClass? {
        if let known = classify(address: host) { return known }
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if lower == "localhost" { return .loopback }
        if lower.hasSuffix(".local") || lower.hasSuffix(".home.arpa") || lower.hasSuffix(".lan") { return .lan }
        return nil
    }

    static func classify(v4 bytes: [UInt8]) -> EndpointClass {
        guard bytes.count == 4 else { return .wan }
        switch (bytes[0], bytes[1]) {
        case (127, _): return .loopback
        case (10, _): return .lan
        case (172, 16...31): return .lan
        case (192, 168): return .lan
        case (169, 254): return .lan
        case (100, 64...127): return .vpn
        default: return .wan
        }
    }

    static func classify(v6 bytes: [UInt8]) -> EndpointClass {
        guard bytes.count == 16 else { return .wan }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
        // IPv4-mapped (::ffff:a.b.c.d): the IPv4 rules.
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return classify(v4: Array(bytes[12..<16]))
        }
        if bytes[0] & 0xFE == 0xFC { return .lan }                 // fc00::/7, unique local
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return .lan } // fe80::/10, link-local
        return .wan
    }
}

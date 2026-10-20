public import Foundation
public import Security
import CryptoKit
import Network
import Synchronization

/// How a `WsClient` protects its connection to the daemon's device listener (docs/architecture.md §2, S1).
///
/// `@unchecked Sendable`: `SecIdentity` is an immutable CF reference the Security framework uses from any thread.
public enum TransportSecurity: @unchecked Sendable {
    /// TLS 1.3 with this device's identity as the client certificate. The server is trusted by its SPKI SHA-256
    /// alone (pinned self-signed certificates, no CA, no hostname check).
    ///
    /// With `serverSPKIPin` nil (pairing), every server is accepted and its SPKI hash is handed to `onServerSPKI`
    /// (called during the handshake, on a Network.framework queue): trust on first use, which the pairing flow
    /// confirms with the SAS before pinning it. With a pin, a different
    /// SPKI fails the connection and the client stops reconnecting (`ConnectionState.failed`).
    case mutualTLS(identity: SecIdentity, serverSPKIPin: Data?, onServerSPKI: @Sendable (Data) -> Void)
    /// No TLS: loopback hosts only (tests, a daemon on this Mac during development). `WsClient` refuses it for any
    /// other host.
    case plaintext

    var isTLS: Bool {
        if case .plaintext = self { return false }
        return true
    }

    /// Whether `host` names this machine: `localhost` or a loopback address. Names that merely resolve to loopback
    /// don't count, so plaintext can't be pointed elsewhere by DNS.
    public static func isLoopback(_ host: String) -> Bool {
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        // All of 127.0.0.0/8, not just 127.0.0.1.
        if let address = IPv4Address(host) { return address.rawValue.first == 127 }
        if let address = IPv6Address(host) { return address.isLoopback }
        return false
    }
}

/// SubjectPublicKeyInfo hashing of a peer certificate, the identity both sides pin (the daemon hashes the same DER
/// with OpenSSL's `i2d_X509_PUBKEY`). Internal: VHIdentity's `SPKI` is the public one, for our own keys.
enum CertificateSPKI {
    /// SHA-256 of the certificate's DER SubjectPublicKeyInfo, or nil when the certificate doesn't parse.
    static func sha256(of certificate: SecCertificate) -> Data? {
        let der = SecCertificateCopyData(certificate) as Data
        return subjectPublicKeyInfo(certificateDER: der).map { Data(SHA256.hash(data: $0)) }
    }

    /// The SubjectPublicKeyInfo element of a DER X.509 certificate, byte for byte as the certificate carries it.
    ///
    /// Taken from the certificate rather than rebuilt from `SecCertificateCopyKey`: the external representation of
    /// a key is the raw point or modulus, not the SPKI, and re-encoding it could differ from what the peer hashes.
    static func subjectPublicKeyInfo(certificateDER der: Data) -> Data? {
        let bytes = [UInt8](der)
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
        guard let certificate = DERElement(bytes, at: 0), certificate.tag == 0x30,
              let tbs = DERElement(bytes, at: certificate.contentStart), tbs.tag == 0x30
        else { return nil }
        // TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber, signature, issuer, validity, subject,
        //                               subjectPublicKeyInfo, ... }
        var cursor = tbs.contentStart
        if let version = DERElement(bytes, at: cursor, end: tbs.end), version.tag == 0xA0 {
            cursor = version.end
        }
        for _ in 0..<5 {
            guard let skipped = DERElement(bytes, at: cursor, end: tbs.end) else { return nil }
            cursor = skipped.end
        }
        guard let spki = DERElement(bytes, at: cursor, end: tbs.end), spki.tag == 0x30 else { return nil }
        return Data(bytes[spki.start..<spki.end])
    }
}

/// One DER TLV: where it starts, where its content starts, and where it ends.
private struct DERElement {
    let tag: UInt8
    let start: Int
    let contentStart: Int
    let end: Int

    init?(_ bytes: [UInt8], at offset: Int, end limit: Int? = nil) {
        let limit = limit ?? bytes.count
        guard offset + 2 <= limit else { return nil }
        tag = bytes[offset]
        start = offset
        var index = offset + 1
        let first = Int(bytes[index])
        index += 1
        var length = 0
        if first < 0x80 {
            length = first
        } else {
            // Long form; 0x80 (indefinite) isn't DER.
            let count = first & 0x7F
            guard count >= 1, count <= 4, index + count <= limit else { return nil }
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard length <= limit - index else { return nil }
        contentStart = index
        end = index + length
    }
}

/// The SPKI a pinned connection was refused for, recorded by the TLS verify block (which runs on its own queue) so
/// the client can tell "wrong server" from a network failure.
final class PinMismatch: Sendable {
    private let observed = Mutex<Data?>(nil)

    func record(_ spki: Data) { observed.withLock { $0 = spki } }
    func take() -> Data? { observed.withLock { value in defer { value = nil }; return value } }
}

extension TransportSecurity {
    /// TLS options for `.mutualTLS`: TLS 1.3 minimum, our identity as the client certificate, and the SPKI check in
    /// place of the system's trust evaluation.
    static func tlsOptions(identity: SecIdentity, pin: Data?, onServerSPKI: @escaping @Sendable (Data) -> Void,
                           mismatch: PinMismatch) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        if let local = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(security, local)
        }
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
                  let spki = CertificateSPKI.sha256(of: leaf)
            else { return complete(false) }
            guard let pin else {
                onServerSPKI(spki)
                return complete(true)
            }
            let matches = spki.count == pin.count && zip(spki, pin).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
            if !matches { mismatch.record(spki) }
            complete(matches)
        }, DispatchQueue.global(qos: .userInitiated))
        return options
    }
}

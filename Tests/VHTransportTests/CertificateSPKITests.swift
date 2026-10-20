import CryptoKit
import Foundation
import Security
import Testing
@testable import VHTransport

@Suite struct CertificateSPKITests {
    /// A self-signed P-256 certificate (`openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1`).
    static let certificateDER = Data(base64Encoded: """
        MIIBYjCCAQigAwIBAgIUbJqRuFRRO9BaobGW+9Q2H5q7Z98wCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMdmgtc3BraS10ZXN0MB4X
        DTI2MTAyMDE4NDQyNVoXDTM2MTAxNzE4NDQyNVowFzEVMBMGA1UEAwwMdmgtc3BraS10ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
        AQcDQgAE3o+9KacoYr7LKJyq+xx7xS0sr6PSYxJ58NJJkSc68Jld155dF4jat6h0sa91PSfTfsbhKTRjdF6vu8mfq23QO6MyMDAw
        HQYDVR0OBBYEFGTQinAF5DD9BVK2K1Qinz3pFZ6GMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAPE31haZTMyF
        fszSyF5e0cjbQRzSdVC6P8SnSdK1FRwsAiAsHxvPhzA5EBvs/cQYtQQ1VpbiTCwprI5or+oW6CMOfw==
        """, options: .ignoreUnknownCharacters)!

    /// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256`
    static let expectedSPKIHash = "f56660c7d5b2114de9afd888cba7937ca18b4f7828e9c068fc38e1db565a2435"

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test func hashesTheSubjectPublicKeyInfoLikeOpenSSL() throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.certificateDER as CFData))
        let hash = try #require(CertificateSPKI.sha256(of: certificate))
        #expect(hex(hash) == Self.expectedSPKIHash)
    }

    @Test func isTheDERWrappedKeyNotTheRawPoint() throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.certificateDER as CFData))
        let spki = try #require(CertificateSPKI.subjectPublicKeyInfo(certificateDER: Self.certificateDER))
        // A P-256 SPKI is the fixed id-ecPublicKey/prime256v1 header followed by the 65-byte uncompressed point.
        let key = try #require(SecCertificateCopyKey(certificate))
        let point = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        let header = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08,
                           0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])
        #expect(spki == header + point)
        #expect(hex(Data(SHA256.hash(data: point))) != Self.expectedSPKIHash)
    }

    @Test func rejectsWhatIsNotACertificate() {
        #expect(CertificateSPKI.subjectPublicKeyInfo(certificateDER: Data()) == nil)
        #expect(CertificateSPKI.subjectPublicKeyInfo(certificateDER: Data([0x30, 0x82, 0xFF])) == nil)
        #expect(CertificateSPKI.subjectPublicKeyInfo(certificateDER: Self.certificateDER.prefix(40)) == nil)
    }
}

import Foundation
import Testing
@testable import VHVault

/// AWS's Signature Version 4 test suite (`aws-sig-v4-test-suite`), as mirrored by awslabs/aws-c-auth
/// `tests/aws-signing-test-suite/v4/<case>/` (`request.txt`, `header-canonical-request.txt`,
/// `header-string-to-sign.txt`, `header-signed-request.txt`, `context.json`): credentials `AKIDEXAMPLE` /
/// `wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY` (AWS's published example key), us-east-1, service `service`,
/// 2015-08-30T12:36:00Z. Each case checks the canonical request, the string to sign and the signature byte for byte.
@Suite struct SigV4Tests {
    static let secret = Data("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY".utf8)
    static let date = Date(timeIntervalSince1970: 1_440_938_160)  // 2015-08-30T12:36:00Z
    static let signer = SigV4(accessKeyID: "AKIDEXAMPLE", region: "us-east-1", service: "service")

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var request: SigV4.Request
        var canonical: String
        var stringToSign: String
        var authorization: String
        var testDescription: String { name }
    }

    static func base(_ method: String, _ path: String, query: [(String, String)] = []) -> SigV4.Request {
        SigV4.Request(method: method, encodedPath: path, query: query,
                      headers: [("Host", "example.amazonaws.com"), ("X-Amz-Date", "20150830T123600Z")],
                      payloadHash: SigV4.emptyPayloadHash, date: date)
    }

    static let cases: [Case] = [
        Case(name: "get-vanilla", request: base("GET", "/"),
             canonical: "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
             stringToSign: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nbb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63",
             authorization: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"),
        Case(name: "get-vanilla-query-order-key-case",
             request: base("GET", "/", query: [("Param2", "value2"), ("Param1", "value1")]),
             canonical: "GET\n/\nParam1=value1&Param2=value2\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
             stringToSign: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n816cd5b414d056048ba4f7c5386d6e0533120fb1fcfa93762cf0fc39e2cf19e0",
             authorization: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"),
        Case(name: "post-vanilla", request: base("POST", "/"),
             canonical: "POST\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
             stringToSign: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n553f88c9e4d10fc9e109e2aeb65f030801b70c2f6468faca261d401ae622fc87",
             authorization: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"),
        Case(name: "get-unreserved",
             request: base("GET", SigV4.uriEncode("/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", keepSlash: true)),
             canonical: "GET\n/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
             stringToSign: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n6a968768eefaa713e2a6b16b589a8ea192661f098f37349f4e2c0082757446f9",
             authorization: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f"),
        Case(name: "post-x-www-form-urlencoded",
             request: SigV4.Request(method: "POST", encodedPath: "/",
                                    headers: [("Content-Type", "application/x-www-form-urlencoded"),
                                              ("Host", "example.amazonaws.com"), ("Content-Length", "13"),
                                              ("X-Amz-Date", "20150830T123600Z"),
                                              ("x-amz-content-sha256", SigV4.sha256Hex(Data("Param1=value1".utf8)))],
                                    payloadHash: SigV4.sha256Hex(Data("Param1=value1".utf8)), date: date),
             canonical: "POST\n/\n\ncontent-length:13\ncontent-type:application/x-www-form-urlencoded\nhost:example.amazonaws.com\nx-amz-content-sha256:9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e\nx-amz-date:20150830T123600Z\n\ncontent-length;content-type;host;x-amz-content-sha256;x-amz-date\n9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e",
             stringToSign: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nb1edd1d03544c25390e32085d55b57acc9a3961bb59415ff86c45c3d89d16cfb",
             authorization: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=content-length;content-type;host;x-amz-content-sha256;x-amz-date, Signature=d3875051da38690788ef43de4db0d8f280229d82040bfac253562e56c3f20e0b"),
    ]

    @Test(arguments: cases) func awsTestSuite(_ c: Case) {
        #expect(Self.signer.canonicalRequest(c.request) == c.canonical)
        #expect(Self.signer.stringToSign(c.request) == c.stringToSign)
        let authorization = Self.secret.withUnsafeBytes { Self.signer.authorization(c.request, secret: $0) }
        #expect(authorization == c.authorization)
    }

    @Test func encodingFollowsS3() {
        #expect(SigV4.uriEncode("/b/o/a b+c", keepSlash: true) == "/b/o/a%20b%2Bc")
        #expect(SigV4.uriEncode(".vaulthalla/root", keepSlash: false) == ".vaulthalla%2Froot")
        #expect(SigV4.canonicalQuery([("versions", ""), ("prefix", ".vaulthalla/")]) == "prefix=.vaulthalla%2F&versions=")
        #expect(SigV4.amzDate(Self.date) == "20150830T123600Z")
    }
}

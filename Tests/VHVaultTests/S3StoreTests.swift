import Foundation
import Testing
@testable import VHVault

/// The S3 store's request building and answer parsing, with no network (the live test sends them).
@Suite struct S3StoreTests {
    static let secret = Data("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY".utf8)

    func request(_ call: S3Store.Call, endpoint: String = "https://s3.us-west-004.backblazeb2.com") throws -> URLRequest {
        try Self.secret.withUnsafeBytes { s in
            try S3Store.request(call, credentials: S3Credentials(accessKeyID: "AKIAEXAMPLE", secret: s, bucket: "vhc-abc",
                                                                 endpoint: endpoint, region: "us-west-004"),
                                date: Date(timeIntervalSince1970: 1_800_000_000))
        }
    }

    @Test func requestsArePathStyleSignedAndCarryNoSecret() throws {
        let r = try request(S3Store.Call(method: "GET", key: "o/abc", query: [("versionId", "v/1+2")], headers: [("range", "bytes=0-9")]))
        #expect(r.url?.absoluteString == "https://s3.us-west-004.backblazeb2.com/vhc-abc/o/abc?versionId=v%2F1%2B2")
        let auth = try #require(r.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/20270115/us-west-004/s3/aws4_request, "))
        #expect(auth.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"))
        #expect(r.value(forHTTPHeaderField: "x-amz-content-sha256") == SigV4.emptyPayloadHash)
        let everything = (r.allHTTPHeaderFields ?? [:]).map { "\($0): \($1)" }.joined() + (r.url?.absoluteString ?? "")
        #expect(!everything.contains("wJalrXUtnFEMI"))
    }

    @Test func plainHTTPOnlyToLoopback() throws {
        #expect(throws: StoreError.self) { _ = try request(S3Store.Call(method: "HEAD", key: "k"), endpoint: "http://10.0.0.11:9000") }
        let r = try request(S3Store.Call(method: "HEAD", key: "k"), endpoint: "http://127.0.0.1:9000")
        #expect(r.url?.absoluteString == "http://127.0.0.1:9000/vhc-abc/k")
    }

    @Test func parsesVersionListingsInOrderWithDeleteMarkers() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><ListVersionsResult><Name>b</Name><IsTruncated>true</IsTruncated>
        <NextKeyMarker>o/b</NextKeyMarker><NextVersionIdMarker>v3</NextVersionIdMarker>
        <Version><Key>o/a</Key><VersionId>v2</VersionId><IsLatest>true</IsLatest><LastModified>2027-01-15T08:00:00.000Z</LastModified><ETag>"e2"</ETag><Size>10</Size></Version>
        <DeleteMarker><Key>o/a</Key><VersionId>v1</VersionId><IsLatest>false</IsLatest><LastModified>2027-01-15T07:00:00Z</LastModified></DeleteMarker>
        </ListVersionsResult>
        """
        let page = XMLRecords.parse(Data(xml.utf8), records: ["Version", "DeleteMarker"])
        #expect(page.records.map(\.element) == ["Version", "DeleteMarker"])
        #expect(page.records[0].fields["ETag"] == "\"e2\"" && page.records[0].fields["Size"] == "10")
        #expect(page.top["IsTruncated"] == "true" && page.top["NextVersionIdMarker"] == "v3")
        #expect(S3Store.seconds("2027-01-15T08:00:00.000Z") == S3Store.seconds("2027-01-15T08:00:00Z"))
        #expect(S3Store.seconds("2027-01-15T08:00:00Z") == 1_800_000_000)
    }

    @Test func providerErrorsNameTheCodeOnly() {
        let xml = "<Error><Code>SignatureDoesNotMatch</Code><AWSAccessKeyId>AKIAEXAMPLE</AWSAccessKeyId><StringToSign>x</StringToSign></Error>"
        let r = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        let text = S3Store.failure(Data(xml.utf8), r)
        #expect(text == "the storage provider answered 403 SignatureDoesNotMatch")
    }

    @Test func contentRangeTotals() {
        func r(_ v: String) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": v])!
        }
        #expect(S3Store.total(r("bytes 0-9/1234")) == 1234)
        #expect(S3Store.total(r("bytes */77")) == 77)
    }
}

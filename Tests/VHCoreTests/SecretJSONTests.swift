import Foundation
import Testing
import VHCore

@Suite struct SecretJSONTests {
    private func lift(_ text: String, _ members: Set<String> = ["key"]) throws -> SecretJSON.Lifted {
        let bytes = Array(text.utf8)
        return try bytes.withUnsafeBytes { raw in try SecretJSON.lift(raw, members: members) }
    }

    private func bytes(_ secret: SecretBytes) -> [UInt8] { secret.withUnsafeBytes { Array($0) } }

    @Test func liftsKeysAtAnyDepthAndRedactsThem() throws {
        let k1 = Data(repeating: 1, count: 32).base64EncodedString()
        let k2 = Data(repeating: 2, count: 32).base64EncodedString()
        let frame = #"{"status":"OK","data":{"vault_id":7,"key": "\#(k1)","key_check":"abc","key_info":{"key_version":2},"historical_keys":[{"key_version":1,"key":"\#(k2)"}]}}"#
        let lifted = try lift(frame)
        let redacted = String(decoding: lifted.redacted, as: UTF8.self)
        #expect(!redacted.contains(k1) && !redacted.contains(k2))
        #expect(redacted.contains(#""key": "secret:0""#) && redacted.contains(#""key":"secret:1""#))
        #expect(redacted.contains(#""key_check":"abc""#), "only the named members are lifted")
        #expect(lifted.secrets.count == 2)
        #expect(bytes(try #require(lifted.secret(for: "secret:0"))) == [UInt8](repeating: 1, count: 32))
        #expect(bytes(try #require(lifted.secret(for: "secret:1"))) == [UInt8](repeating: 2, count: 32))
        #expect(lifted.secret(for: "secret:2") == nil && lifted.secret(for: "abc") == nil)
        // The redacted copy is valid JSON.
        _ = try JSONSerialization.jsonObject(with: lifted.redacted)
    }

    @Test func aMemberNameInsideAStringIsNotAMember() throws {
        let frame = #"{"name":"\"key\":\"AAAA\"","key":"AQID"}"#
        let lifted = try lift(frame)
        #expect(lifted.secrets.count == 1 && bytes(lifted.secrets[0]) == [1, 2, 3])
        #expect(String(decoding: lifted.redacted, as: UTF8.self) == #"{"name":"\"key\":\"AAAA\"","key":"secret:0"}"#)
    }

    @Test func escapedSlashesAreBase64() throws {
        let raw = Data([0xFB, 0xFF, 0xBF]).base64EncodedString() // "+/+/"
        let escaped = raw.replacingOccurrences(of: "/", with: "\\/")
        let lifted = try lift(#"{"key":"\#(escaped)"}"#)
        #expect(bytes(lifted.secrets[0]) == [0xFB, 0xFF, 0xBF])
    }

    @Test func malformedInputIsRefused() throws {
        #expect(throws: SecretJSON.Failure.malformedSecret) { try lift(#"{"key":"not base64!"}"#) }
        #expect(throws: SecretJSON.Failure.malformedSecret) { try lift(#"{"key":""}"#) }
        #expect(throws: SecretJSON.Failure.malformedSecret) { try lift(#"{"key":"AA\nA"}"#) }
        #expect(throws: SecretJSON.Failure.malformed) { try lift(#"{"key":"AAAA"#) }
        // A non-string value under a secret name is left alone.
        #expect(try lift(#"{"key":null}"#).secrets.isEmpty)
    }

    @Test func writerProducesJSONWithBase64FromSecretBytes() throws {
        let key = SecretBytes((0..<32).map { UInt8($0) })
        let w = SecretJSONWriter(capacity: 8) // grows (and wipes) several times
        w.beginObject()
        w.field("vault_id", Int64(42))
        w.field("name", "Ph\"o\\tos\n\u{1}")
        w.key("key")
        w.base64(key)
        w.key("list")
        w.beginArray()
        w.int(1)
        w.bool(true)
        w.null()
        w.beginObject()
        w.endObject()
        w.endArray()
        w.endObject()
        let document = w.finish()
        let parsed = try JSONSerialization.jsonObject(with: Data(bytes(document))) as? [String: Any]
        #expect(parsed?["vault_id"] as? Int == 42)
        #expect(parsed?["name"] as? String == "Ph\"o\\tos\n\u{1}")
        #expect(parsed?["key"] as? String == Data((0..<32).map { UInt8($0) }).base64EncodedString())
        #expect((parsed?["list"] as? [Any])?.count == 4)
    }

    @Test func writerBase64MatchesFoundationForEveryLength() throws {
        for length in 1...20 {
            let raw = (0..<length).map { UInt8(truncatingIfNeeded: $0 * 37 + 5) }
            let w = SecretJSONWriter()
            w.base64(SecretBytes(raw))
            let text = String(decoding: bytes(w.finish()), as: UTF8.self)
            #expect(text == "\"\(Data(raw).base64EncodedString())\"")
            // And back through the reader.
            let lifted = try lift(#"{"key":\#(text)}"#)
            #expect(bytes(lifted.secrets[0]) == raw)
        }
    }
}

import Foundation
import Testing
import VHCore
@testable import VHOnePassword

@Suite struct WireFormatTests {
    private func line(_ build: (inout RequestLineWriter) -> Void) -> [UInt8] {
        var writer = RequestLineWriter(id: 7, op: "item.upsert", capacity: 16)
        build(&writer)
        let buffer = writer.finish()
        return buffer.withUnsafeBytes { Array($0) }
    }

    @Test func requestLineIsOneJSONObjectWithEscapedStrings() throws {
        let tricky = "a\"b\\c\nd\t\u{1}é · 🔑"
        let key = SecretBytes([0, 1, 2, 250, 251, 252, 253])
        let bytes = line { w in
            w.field("node_name", tricky)
            w.field("current_version", 3)
            w.key("versions")
            w.beginArray()
            w.beginObject()
            w.field("version", 3)
            w.key("key_b64")
            w.base64(key)
            w.key("needed")
            w.bool(true)
            w.endObject()
            w.beginObject()
            w.field("version", 2)
            w.endObject()
            w.endArray()
            w.key("list")
            w.beginArray()
            w.int(1)
            w.int(2)
            w.endArray()
        }
        #expect(bytes.last == UInt8(ascii: "\n"))
        #expect(bytes.filter { $0 == UInt8(ascii: "\n") }.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        #expect(object["id"] as? Int == 7)
        #expect(object["op"] as? String == "item.upsert")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["node_name"] as? String == tricky)
        #expect(params["current_version"] as? Int == 3)
        #expect(params["list"] as? [Int] == [1, 2])
        let versions = try #require(params["versions"] as? [[String: Any]])
        #expect(versions.count == 2)
        #expect(versions[0]["key_b64"] as? String == Data([0, 1, 2, 250, 251, 252, 253]).base64EncodedString())
        #expect(versions[0]["needed"] as? Bool == true)
        #expect(versions[1]["version"] as? Int == 2)
    }

    @Test func base64MatchesFoundationForEveryLength() {
        var generator = SystemRandomNumberGenerator()
        for length in 0...70 {
            let raw = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            var buffer = SecureByteBuffer(capacity: 1)
            buffer.appendBase64(SecretBytes(raw))
            let encoded = buffer.withUnsafeBytes { Array($0) }
            #expect(String(decoding: encoded, as: UTF8.self) == Data(raw).base64EncodedString(), "length \(length)")
            if length > 0 {
                let decoded = encoded.withUnsafeBytes { Base64.decodeSecret($0) }
                #expect(decoded?.withUnsafeBytes { Array($0) } == raw, "length \(length)")
            }
        }
    }

    @Test(arguments: ["", "abc", "a===", "ab$=", "=AAA", "AA=A", "AAAA====", "ab\"c"])
    func base64RejectsMalformedText(_ text: String) {
        let decoded = Array(text.utf8).withUnsafeBytes { Base64.decodeSecret($0) }
        #expect(decoded == nil)
    }

    @Test func secureBufferWipes() {
        var buffer = SecureByteBuffer(capacity: 4)
        buffer.append("secret material that forces the buffer to grow")
        buffer.wipe()
        let empty = buffer.isEmpty
        let capacity = buffer.bytes.capacity
        #expect(empty && capacity >= 4)
    }

    @Test func responseSecretsAreLiftedOutAndRedacted() throws {
        let k1 = Data(repeating: 1, count: 32).base64EncodedString()
        let k2 = Data((0..<17).map { UInt8($0) }).base64EncodedString()
        let text = #"{"id":3,"ok":true,"result":{"note":"\"key_b64\":\"QUFB\"","versions":[{"version":2,"key_b64":"\#(k2)"},{"version":1,"key_b64":"\#(k1)"}]}}"#
        var raw = Array(text.utf8)
        let response = try ResponseLine.take(&raw)

        #expect(raw.allSatisfy { $0 == 0 }, "the raw line is zeroed")
        #expect(response.secrets.count == 2)
        #expect(response.secrets[0].withUnsafeBytes { Array($0) } == (0..<17).map { UInt8($0) })
        #expect(response.secrets[1].withUnsafeBytes { Array($0) } == [UInt8](repeating: 1, count: 32))
        let redacted = String(decoding: response.redacted, as: UTF8.self)
        #expect(!redacted.contains(k1) && !redacted.contains(k2))
        #expect(redacted.contains(#"\"key_b64\":\"QUFB\""#), "an escaped look-alike inside a string is left alone")
        // Still valid JSON.
        let object = try #require(JSONSerialization.jsonObject(with: response.redacted) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
    }

    @Test func malformedSecretIsRejected() {
        var unterminated = Array(#"{"id":1,"result":{"key_b64":"QUFB"#.utf8)
        #expect(throws: ResponseLine.Failure.malformedSecret) { try ResponseLine.take(&unterminated) }
        var bad = Array(#"{"id":1,"result":{"key_b64":"not base64!"}}"#.utf8)
        #expect(throws: ResponseLine.Failure.malformedSecret) { try ResponseLine.take(&bad) }
        #expect(bad.allSatisfy { $0 == 0 })
    }

    @Test func backupItemDecodingIsLenientAboutTimestamps() throws {
        let json = #"""
        {"items":[{"item_id":"i","vault_id":"v","title":"t","node_id":"n","node_name":"N","vault_uuid":"u",
          "vault_name":"V","current_version":2,"key_check":"c2",
          "versions":[{"version":2,"key_check":"c2","state":"current"},{"version":1,"key_check":"c1","state":"weird"}],
          "updated_at":"2026-10-20T12:00:00Z","backed_up_at":"yesterday-ish","issues":[]}]}
        """#
        let decoded = try JSONDecoder().decode(WireItems.self, from: Data(json.utf8))
        let item = try #require(decoded.items.first)
        #expect(item.updatedAt == Date(timeIntervalSince1970: 1_792_497_600))
        #expect(item.backedUpAt == nil)
        #expect(item.versions == [
            StoredKeyVersion(version: 2, keyCheck: "c2", state: .current),
            StoredKeyVersion(version: 1, keyCheck: "c1", state: .other("weird")),
        ])
        #expect(item.version(1)?.keyCheck == "c1")
    }
}

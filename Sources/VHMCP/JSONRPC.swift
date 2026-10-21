import Foundation
import VHContract

/// The JSON-RPC 2.0 messages the bridge reads and writes, as `JSONValue`s: a node's results pass through without
/// being decoded into narrower types (and losing members the bridge doesn't know).
enum RPC {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603

    static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .integer(Int64(code)), "message": .string(message)]]
    }

    /// An answer carrying a node's `error` member as it came.
    static func error(id: JSONValue, verbatim error: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": error]
    }

    static func request(id: Int64, method: String, params: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": .integer(id), "method": .string(method), "params": params]
    }

    static func notification(_ method: String, params: JSONValue? = nil) -> JSONValue {
        var object: JSONObject = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { object["params"] = params }
        return .object(object)
    }

    /// A tool result the bridge makes itself: one text block, and the structured form when there is one.
    static func toolResult(text: String, structured: JSONValue? = nil, isError: Bool) -> JSONValue {
        var object: JSONObject = [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(isError),
        ]
        if let structured { object["structuredContent"] = structured }
        return .object(object)
    }

    /// One line of the stdio transport: compact JSON, never a raw newline (JSONEncoder escapes control characters).
    static func encodeLine(_ message: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = (try? encoder.encode(message)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
        data.append(0x0A)
        return data
    }

    /// Pretty JSON for a text content block.
    static func prettyText(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Where the bridge's diagnostics go: stderr in the helper, never stdout (that carries only protocol messages).
/// Messages name methods, tools, nodes and failures; never tool arguments or results, which may hold user data.
public struct BridgeLog: Sendable {
    public enum Level: Int, Sendable, Comparable {
        case debug, info, warning, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var minimum: Level
    private let sink: @Sendable (String) -> Void

    public init(minimum: Level = .info, sink: @escaping @Sendable (String) -> Void) {
        self.minimum = minimum
        self.sink = sink
    }

    /// Lines on stderr, prefixed `vaulthalla-mcp:`.
    public static func standardError(minimum: Level = .info) -> BridgeLog {
        BridgeLog(minimum: minimum) { line in
            try? FileHandle.standardError.write(contentsOf: Data("vaulthalla-mcp: \(line)\n".utf8))
        }
    }

    public static let silent = BridgeLog(minimum: .error) { _ in }

    public func callAsFunction(_ level: Level, _ message: @autoclosure () -> String) {
        guard level >= minimum else { return }
        sink(message())
    }
}

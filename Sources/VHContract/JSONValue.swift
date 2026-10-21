/// Any JSON value: the raw escape hatch for commands not in the contract yet, and what the generated types fall back
/// to where the contract can't say more (several JSON types without a `one_of`, array elements it leaves untyped).
///
/// Integers decode as `.integer` (ids are 64-bit and must not round-trip through `Double`); any other number is
/// `.number`.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// The member `key` of an object; nil for anything else or a missing member.
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var isNull: Bool { self == .null }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    /// Integers widen to `Double`.
    public var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }
}

/// A JSON object. The generated types use it for objects the contract leaves open (free-form metadata, audit
/// details); the models it names are typed (`WsModel.User`, ...).
public typealias JSONObject = [String: JSONValue]

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode(JSONObject.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// Deliberately not ExpressibleByNilLiteral: `nil` must stay `Optional.none` wherever a `JSONValue?` is involved
// (an absent member), never silently become `.null`.
extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A member that is optional *and* nullable in the contract: as `Nullable<T>?`, nil leaves the key out (the daemon
/// keeps what it has) and `.null` sends an explicit null (the daemon clears it). A plain `T?` can't tell the two
/// apart.
public enum Nullable<Wrapped> {
    case null
    case value(Wrapped)

    /// The value, or nil for `.null`.
    public var wrapped: Wrapped? {
        if case .value(let value) = self { return value }
        return nil
    }
}

extension Nullable: Equatable where Wrapped: Equatable {}
extension Nullable: Hashable where Wrapped: Hashable {}
extension Nullable: Sendable where Wrapped: Sendable {}

extension Nullable: Codable where Wrapped: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = container.decodeNil() ? .null : .value(try container.decode(Wrapped.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .value(let value): try container.encode(value)
        }
    }
}

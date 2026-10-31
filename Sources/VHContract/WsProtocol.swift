/// The ws protocol range this build speaks, and the names `meta.hello` negotiates with (docs/architecture.md §3,
/// "Protocol negotiation"). Hand-written: the contract says what a command looks like; this says which daemons this
/// build agrees to talk to at all.
///
/// Protocol versions are integers the daemon bumps only for a breaking change; protocol 1 starts with the first
/// daemon that answers `meta.hello`. A daemon that predates `meta.hello` (≤ 1.18.0) is *legacy*: protocol 1 assumed,
/// no capability or command list, every feature check falls back to trying the command.
public enum WsProtocol {
    /// The oldest protocol this build speaks.
    public static let minimum = 1
    /// The newest protocol this build speaks.
    public static let maximum = 1
    /// `minimum...maximum`.
    public static var supported: ClosedRange<Int> { minimum...maximum }

    /// The version a legacy daemon (no `meta.hello`) is taken to speak.
    public static let legacyVersion = 1
    /// The oldest daemon release this build still works with: the generator's compatibility baseline
    /// (contract/compat-baseline.json), whose response members newer ones may add are optional in the generated types.
    public static var oldestServer: String { WsContract.baselineServerVersion }
    /// The newest daemon release that predates `meta.hello`: a legacy node runs this or an older one.
    public static let newestLegacyServer = "1.18"
    /// What this client calls itself in `meta.hello`.
    public static let clientName = "vaulthalla-desktop"
}

/// A capability a daemon announces in `meta.hello`: a stable dotted name for a behaviour that isn't a command of its
/// own (a typed refusal code, an HTTP lane, a response member). Whether a *command* exists comes from the hello's
/// `commands` list instead.
public struct WsCapability: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    /// Device sessions get `data.code` "unknown_command" for a command the daemon doesn't have.
    public static let unknownCommandCode: WsCapability = "errors.unknown_command_code"
    /// `FsEntry` carries `metadata_version` (and `content_version`).
    public static let fsEntryMetadataVersion: WsCapability = "fs.entry.metadata_version"
    /// The device listener serves `/preview` and `/preview/batch`.
    public static let previewLane: WsCapability = "device.lanes.preview"
    /// The device listener serves `/download` and `/download/content`.
    public static let downloadLane: WsCapability = "device.lanes.download"
    /// The device listener serves the `/upload` session flow.
    public static let uploadLane: WsCapability = "device.lanes.upload"
    /// The device listener serves `/mcp` (remote MCP for paired devices).
    public static let deviceMCP: WsCapability = "device.mcp"
    /// `device.server.identity` answers the server key's SPKI hash on device sessions.
    public static let serverIdentity: WsCapability = "device.server.identity"
    /// ws `device.endpoints` on Device sessions, and `endpoints` in `device.pairing.open` (the server's
    /// docs/reference/transfer-protocol.md §1).
    public static let deviceEndpoints: WsCapability = "device.endpoints"
    /// The device listener's calibration routes `/transfer/probe`, `/transfer/sink` and `/transfer/source` (§4).
    public static let transferLane: WsCapability = "device.lanes.transfer"
    /// `/upload/sessions`: resumable uploads in parts (§3), on both listeners.
    public static let resumableUpload: WsCapability = "http.upload.resumable"

    /// The capabilities this build looks for (each one is in the vendored contract's `WsContract.capabilities`, except
    /// those in ``awaitingContract``).
    public static let used: [WsCapability] = [
        .unknownCommandCode, .fsEntryMetadataVersion, .previewLane, .downloadLane, .uploadLane, .deviceMCP,
        .serverIdentity, .deviceEndpoints, .transferLane, .resumableUpload,
    ]

    /// Capabilities the normative spec (the server's `docs/reference/transfer-protocol.md`, server 1.20.0) defines
    /// but the vendored contract doesn't declare yet (the server publishes them as it implements them). Remove one once
    /// `tools/gen-contract.py --from` vendors a contract that has it (a test fails as soon as it does).
    public static let awaitingContract: Set<WsCapability> = []
}

/// Whether a node has a command or a capability: known either way once `meta.hello` answered, unknown on a legacy
/// node (or before the hello answered), where the feature is tried and an "Unknown command" read as no.
public enum ProtocolSupport: Hashable, Sendable {
    case yes
    case no
    /// A legacy node, or not negotiated yet: try it and interpret the refusal (`WsError.isUnknownCommand`).
    case unknown

    public init(_ known: Bool?) {
        switch known {
        case true?: self = .yes
        case false?: self = .no
        case nil: self = .unknown
        }
    }

    /// The answer when a legacy fallback has to decide: unknown counts as `assumingLegacy`.
    public func resolved(assumingLegacy legacy: Bool) -> Bool {
        switch self {
        case .yes: true
        case .no: false
        case .unknown: legacy
        }
    }
}

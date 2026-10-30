import Foundation
import Testing
import VHContract
@testable import VHNodes
import VHTransport

/// `meta.hello` outcomes (`NodeProtocol.outcome(of:)`) and the tri-state support checks, without a daemon.
@Suite struct NodeProtocolTests {
    private func hello(version: Int = 1, min: Int = 1, max: Int = 1, release: String = "1.19.0",
                       capabilities: [String] = ["device.mcp", "errors.unknown_command_code"],
                       commands: [String] = ["meta.hello", "storage.vault.accessible.list"]) -> HelloResponse {
        HelloResponse(server: .init(name: "vaulthalla", version: release),
                      protocol: .init(version: Int64(version), min: Int64(min), max: Int64(max)), capabilities: capabilities,
                      commands: commands,
                      contract: .init(contractVersion: 3, contractHash: "c", wsHash: WsContract.wsHash, modelsHash: "m"))
    }

    @Test func negotiated() throws {
        let settled = try #require(NodeProtocol.outcome(of: .success(hello())))
        #expect(settled.state == .negotiated)
        #expect(settled.version == 1)
        #expect(settled.serverName == "vaulthalla" && settled.serverVersion == "1.19.0")
        #expect(settled.serverRange == 1...1)
        #expect(settled.contract?.matchesThisBuild == true)
        #expect(settled.mismatch == nil && !settled.isLegacy)
        #expect(settled.productLabel == "Vaulthalla 1.19.0 · protocol 1")
    }

    @Test(arguments: [WsError.error("Unknown command"), .unknownCommand("Unknown command"),
                      .invalid("unknown action 'export'")])
    func legacyFromUnknownCommand(error: WsError) throws {
        let settled = try #require(NodeProtocol.outcome(of: .failure(error)))
        #expect(settled == .legacy)
        #expect(settled.version == WsProtocol.legacyVersion)
        #expect(settled.serverVersion == nil && settled.capabilities == nil && settled.commands == nil)
        #expect(settled.productLabel == "Vaulthalla 1.18 or earlier")
    }

    @Test func incompatibleFromProtocolUnsupported() throws {
        let newer = ProtocolMismatch(serverMin: 2, serverMax: 3, serverVersion: "2.0.0")
        let settled = try #require(NodeProtocol.outcome(of: .failure(.protocolUnsupported(newer))))
        #expect(settled.state == .incompatible(serverMin: 2, serverMax: 3, serverVersion: "2.0.0", reason: .desktopTooOld))
        #expect(settled.version == nil && settled.serverRange == 2...3)
        #expect(settled.mismatch == newer)
        #expect(newer.message == "This node runs Vaulthalla 2.0.0, which needs a newer Vaulthalla Desktop. "
            + "Update Vaulthalla Desktop.")

        let older = ProtocolMismatch(serverMin: 0, serverMax: 0, serverVersion: "1.30.0")
        #expect(older.side == .serverTooOld)
        #expect(older.message.hasSuffix("speaks an older protocol: update Vaulthalla on the node."))
        #expect(ProtocolMismatch(serverMin: nil, serverMax: nil, serverVersion: nil).side == .unclear)
    }

    @Test func aVersionOutsideThisBuildsRangeIsIncompatible() throws {
        // A daemon that picked a version this build never offered.
        let settled = try #require(NodeProtocol.outcome(of: .success(hello(version: 2, min: 2, max: 2))))
        #expect(settled.mismatch?.side == .desktopTooOld)
        #expect(settled.supports(command: "meta.hello") == .no)
    }

    @Test(arguments: [WsError.timeout, .disconnected, .denied("no"), .contractMismatch("meta.hello: missing server"),
                      .refused(code: "device_unknown", message: "Unknown device.")])
    func undecidedOutcomes(error: WsError) {
        #expect(NodeProtocol.outcome(of: .failure(error)) == nil)
    }

    @Test func triStateSupport() throws {
        let negotiated = try #require(NodeProtocol.outcome(of: .success(hello())))
        #expect(negotiated.supports(command: .storageVaultAccessibleList) == .yes)
        #expect(negotiated.supports(command: .syncConflictsSummary) == .no)
        #expect(negotiated.supports(capability: .deviceMCP) == .yes)
        #expect(negotiated.supports(capability: .previewLane) == .no)

        // Legacy: nothing is known; feature code tries and reads the refusal.
        #expect(NodeProtocol.legacy.supports(command: .storageVaultAccessibleList) == .unknown)
        #expect(NodeProtocol.legacy.supports(capability: .deviceMCP) == .unknown)

        // Incompatible: nothing is sent, so nothing is supported.
        let incompatible = try #require(NodeProtocol.outcome(of: .failure(
            .protocolUnsupported(ProtocolMismatch(serverMin: 2, serverMax: 2, serverVersion: "2.0.0")))))
        #expect(incompatible.supports(command: .storageVaultList) == .no)
        #expect(incompatible.supports(capability: .deviceMCP) == .no)

        #expect(ProtocolSupport.unknown.resolved(assumingLegacy: true))
        #expect(!ProtocolSupport.no.resolved(assumingLegacy: true))
    }

    @MainActor @Test func queriesReportWhatTheSessionNegotiated() {
        let queries = NodeQueries(transport: NoTransport())
        #expect(queries.supports(command: .storageVaultAccessibleList) == .unknown)
        queries.protocolChanged(NodeProtocol.outcome(of: .success(hello())))
        #expect(queries.supports(command: .storageVaultAccessibleList) == .yes)
        #expect(queries.supports(capability: .previewLane) == .no)
        #expect(queries.incompatibility == nil)
        queries.protocolChanged(.legacy)
        #expect(queries.supports(command: .storageVaultAccessibleList) == .unknown)
    }

    @Test func helloPayloadMatchesTheSpec() throws {
        let payload = Ws.Meta.Hello.Payload(thisBuild: "0.2.0")
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
        #expect(json == ["client": ["name": "vaulthalla-desktop", "version": "0.2.0"],
                         "protocol": ["min": .integer(Int64(WsProtocol.minimum)),
                                      "max": .integer(Int64(WsProtocol.maximum))]])
    }

    @Test func helloResponseDecodes() throws {
        let frame = #"""
        {"server": {"name": "vaulthalla", "version": "1.19.0"},
         "protocol": {"version": 1, "min": 1, "max": 1},
         "capabilities": ["device.lanes.preview", "fs.entry.metadata_version"],
         "commands": ["fs.entry.get", "meta.hello"],
         "contract": {"contract_version": 3, "contract_hash": "a", "ws_hash": "b", "models_hash": "c"}}
        """#
        let decoded = try JSONDecoder().decode(HelloResponse.self, from: Data(frame.utf8))
        let settled = try #require(NodeProtocol.outcome(of: .success(decoded)))
        #expect(settled.supports(capability: .fsEntryMetadataVersion) == .yes)
        #expect(settled.supports(command: "fs.entry.get") == .yes)
        #expect(settled.contract == .init(contractVersion: 3, contractHash: "a", wsHash: "b", modelsHash: "c"))
    }
}

/// A transport that never answers (the queries under test only report protocol state).
private struct NoTransport: NodeTransport {
    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response {
        throw .disconnected
    }
}

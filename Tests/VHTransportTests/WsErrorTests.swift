import Foundation
import Testing
import VHContract
import VHCore
@testable import VHTransport

/// How refusals are classified (`WsError.classify`): typed kinds, confirmations a command declares, codes it doesn't,
/// the typed unknown command, `protocol_unsupported`, and the legacy "Unknown command" words.
@Suite struct WsErrorClassificationTests {
    private func classify(_ code: String?, _ text: String = "text", command: String? = "auth.user.delete",
                          data: WsError.Refusal? = nil) -> WsError? {
        WsError.classify(status: "ERROR", error: text, refusal: data ?? WsError.Refusal(code: code), command: command)
    }

    @Test func confirmationsAreOnlyTheCommandsOwn() {
        // auth.user.delete declares user_delete.
        #expect(classify("user_delete", "Delete alice?") == .needsConfirmation(code: "user_delete", message: "Delete alice?"))
        // Another command's confirmation code is not a question for this one.
        #expect(classify("vault_delete_now", "x") == .refused(code: "vault_delete_now", message: "x"))
        // A command-specific refusal code and a newer daemon's unknown code: a server error carrying the code.
        #expect(classify("rate_limited", "Slow down", command: "device.pair.request")
            == .refused(code: "rate_limited", message: "Slow down"))
        #expect(classify("brand_new_code", "Something new") == .refused(code: "brand_new_code", message: "Something new"))
        #expect(classify("brand_new_code")?.code == "brand_new_code")
    }

    @Test func untypedCommandsUseEveryDeclaredConfirmation() {
        #expect(classify("user_delete", "q", command: "not.in.the.contract") == .needsConfirmation(code: "user_delete",
                                                                                                    message: "q"))
        #expect(classify("export_requires_device", "x", command: "not.in.the.contract")
            == .refused(code: "export_requires_device", message: "x"))
        #expect(classify("user_delete", "q", command: nil) == .needsConfirmation(code: "user_delete", message: "q"))
    }

    @Test func typedKindsKeepTheirCases() {
        #expect(classify("denied", "No") == .denied("No"))
        #expect(classify("not_found", "Gone") == .notFound("Gone"))
        #expect(classify("invalid", "Bad") == .invalid("Bad"))
        #expect(classify("conflict", "Taken") == .conflict("Taken"))
        #expect(WsError.classify(status: "UNAUTHORIZED", error: "Sign in", refusal: nil, command: nil)
            == .unauthorized("Sign in"))
        #expect(WsError.classify(status: "OK", error: nil, refusal: nil, command: nil) == nil)
    }

    @Test func unknownCommandTypedAndLegacy() {
        let typed = classify("unknown_command", "Unknown command")
        #expect(typed == .unknownCommand("Unknown command"))
        #expect(typed?.isUnknownCommand == true && typed?.code == "unknown_command")
        // A legacy daemon (≤ 1.18.0): the router's words, no code.
        let legacy = classify(nil, "Unknown command")
        #expect(legacy == .error("Unknown command"))
        #expect(legacy?.isUnknownCommand == true && legacy?.code == nil)
        #expect(WsError.notFound("unknown action 'export'").isUnknownCommand)
        #expect(!WsError.error("Rate limit exceeded").isUnknownCommand)
        #expect(!WsError.denied("Unknown command").isUnknownCommand)
    }

    @Test func protocolUnsupportedCarriesTheServersRange() {
        let error = classify(nil, "No common protocol", data: WsError.Refusal(
            code: "protocol_unsupported", serverMin: 2, serverMax: 3, serverVersion: "2.0.0"))
        let expected = ProtocolMismatch(serverMin: 2, serverMax: 3, serverVersion: "2.0.0")
        #expect(error == .protocolUnsupported(expected))
        #expect(expected.side == .desktopTooOld)
        #expect(error?.message.contains("Vaulthalla 2.0.0") == true)
    }
}

@Suite struct WsErrorWireTests {
    private func client(for server: TestServer) throws -> WsClient {
        try WsClient(configuration: .init(endpoint: NodeEndpoint(host: "127.0.0.1", port: server.port),
                                          security: .plaintext, connectTimeout: .seconds(2)))
    }

    @Test func protocolUnsupportedOverTheWire() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let ws = try client(for: server)
        let reply = Task {
            try await ws.send(command: "meta.hello", payload: ["protocol": ["min": 1, "max": 1]] as JSONValue)
        }
        let request = try #require(await server.next())
        request.refuse("No common protocol version.", data: [
            "code": "protocol_unsupported", "server_min": 0, "server_max": 0, "server_version": "1.40.0",
        ])
        let expected = WsError.protocolUnsupported(ProtocolMismatch(serverMin: 0, serverMax: 0, serverVersion: "1.40.0"))
        await #expect(throws: expected) { try await reply.value }
        await ws.close()
    }

    @Test func typedUnknownCommandOverTheWire() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let ws = try client(for: server)
        let reply = Task { try await ws.send(command: "vault.future", payload: [:] as JSONValue) }
        try #require(await server.next()).refuse("Unknown command", code: "unknown_command")
        await #expect(throws: WsError.unknownCommand("Unknown command")) { try await reply.value }
        await ws.close()
    }
}

/// A lane failure read against the node's `device.lanes.*` announcement (`TransferError.interpreted(for:support:)`).
@Suite struct LaneSupportTests {
    @Test func a404IsTheLaneOnlyWhenTheNodeLacksIt() {
        #expect(TransferError.notFound.interpreted(for: .preview, support: .no) == .laneUnavailable(.preview))
        #expect(TransferError.status(404, "").interpreted(for: .upload, support: .no) == .laneUnavailable(.upload))
        // Announced, or unknown (a legacy node): the item is gone, as before.
        #expect(TransferError.notFound.interpreted(for: .download, support: .yes) == .notFound)
        #expect(TransferError.notFound.interpreted(for: .download, support: .unknown) == .notFound)
        // Other failures stand either way.
        #expect(TransferError.forbidden.interpreted(for: .download, support: .no) == .forbidden)
        #expect(TransferError.Lane.download.capability == .downloadLane)
        #expect(TransferError.laneUnavailable(.preview).message.contains("doesn't serve previews"))
    }
}

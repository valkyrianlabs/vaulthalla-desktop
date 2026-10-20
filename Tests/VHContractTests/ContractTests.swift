import Foundation
import Testing
import VHContract

/// One request type's samples (Generated/ContractSamples.swift): `[minimal, full]` JSON for the payload and the
/// response. The checks are type-erased into closures so the table can hold every request type.
struct ContractSample: Sendable, CustomTestStringConvertible {
    let name: String
    let command: WsCommand
    let payload: [String]
    let response: [String]
    /// Decodes the JSON as the request's Payload, encodes it again and returns both as JSONValue.
    let payloadRoundTrip: @Sendable (String) throws -> (sent: JSONValue, decoded: JSONValue)
    /// Same for the Response.
    let responseRoundTrip: @Sendable (String) throws -> (sent: JSONValue, decoded: JSONValue)

    init<R: WsRequest>(_ request: R.Type, payload: [String], response: [String])
    where R.Payload: Decodable, R.Response: Encodable {
        name = String(reflecting: request).replacingOccurrences(of: "VHContract.", with: "")
        command = R.command
        self.payload = payload
        self.response = response
        payloadRoundTrip = { try roundTrip(R.Payload.self, $0) }
        responseRoundTrip = { try roundTrip(R.Response.self, $0) }
    }

    var testDescription: String { name }
}

private func roundTrip<T: Codable>(_ type: T.Type, _ json: String) throws -> (sent: JSONValue, decoded: JSONValue) {
    let data = Data(json.utf8)
    let value = try JSONDecoder().decode(T.self, from: data)
    let encoded = try JSONEncoder().encode(value)
    let decoder = JSONDecoder()
    return (try decoder.decode(JSONValue.self, from: data), try decoder.decode(JSONValue.self, from: encoded))
}

/// The vendored contract, read from the repository (the tests run from a checkout).
private func vendoredContract() throws -> JSONValue {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "contract/wsContract.json")
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

@Suite struct GeneratedContractTests {
    @Test(arguments: contractSamples)
    func responseDecodesAndRoundTrips(sample: ContractSample) throws {
        // Required members only: decodes. Every member: decodes and encodes back to the same JSON, which proves the
        // coding keys and the absent/null handling both ways.
        _ = try sample.responseRoundTrip(sample.response[0])
        let full = try sample.responseRoundTrip(sample.response[1])
        #expect(full.decoded == full.sent)
    }

    @Test(arguments: contractSamples)
    func payloadRoundTrips(sample: ContractSample) throws {
        for json in sample.payload {
            let result = try sample.payloadRoundTrip(json)
            #expect(result.decoded == result.sent)
        }
    }

    @Test func commandsMatchTheVendoredContract() throws {
        let contract = try vendoredContract()
        let entries = try #require(contract["ws"]?.arrayValue)
        #expect(WsCommand.allCases.count == entries.count)
        #expect(WsContract.wsHash == contract["ws_hash"]?.stringValue)
        #expect(Int64(WsContract.contractVersion) == contract["contract_version"]?.integerValue)

        for entry in entries {
            let name = try #require(entry["command"]?.stringValue)
            let command = try #require(WsCommand(rawValue: name), "\(name) has no WsCommand case")
            #expect(command.auth.rawValue == entry["auth"]?.stringValue)
            #expect(command.clientTimeout == .milliseconds(try #require(entry["client_timeout_ms"]?.integerValue)))
            #expect(command.operation == entry["operation"]?.stringValue)
            #expect(command.refusalCodes == entry["refusal_codes"]?.arrayValue?.compactMap(\.stringValue))
            #expect(command.summary == entry["description"]?.stringValue)
        }
        // Every command and every share-mode variant has samples.
        let variants = entries.reduce(0) { $0 + ($1["variants"]?.arrayValue?.count ?? 0) }
        #expect(contractSamples.count == entries.count + variants)
        #expect(Set(contractSamples.map(\.command)).count == entries.count)
    }

    @Test func requiredMembersAreRequired() {
        // `meta.contract.get` requires ws_hash.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Ws.Meta.Contract.Get.Response.self,
                                     from: Data(#"{"contract_version":1,"contract_hash":"h"}"#.utf8))
        }
        // `auth.security.status` requires initial_password_file, even though it may be null.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Ws.Auth.Security.Status.Response.self, from: Data("{}".utf8))
        }
        let status = try? JSONDecoder().decode(Ws.Auth.Security.Status.Response.self,
                                               from: Data(#"{"initial_password_file":null}"#.utf8))
        #expect(status != nil && status?.initialPasswordFile == nil)
    }
}

@Suite struct PayloadEncodingTests {
    private func json(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    @Test func optionalNullableTellsAbsentFromNull() throws {
        // group.update: nil leaves the name alone, .null clears the description.
        let payload = Ws.Group.Update.Payload(id: 7, name: nil, description: .null, linuxGid: .value(1200))
        #expect(try json(payload) == ["id": 7, "description": .null, "linux_gid": 1200])
    }

    @Test func requiredNullableIsAlwaysSent() throws {
        let response = Ws.Auth.Security.Status.Response(initialPasswordFile: nil)
        #expect(try json(response) == ["initial_password_file": .null])
    }

    @Test func enumsUnionsAndNestedStructs() throws {
        let payload = Ws.Share.Link.Create.Payload(
            vaultID: 3, rootEntryID: 41, rootPath: "/docs", targetType: .directory, linkType: .download,
            accessMode: .emailValidated, allowedOps: ["list", "download"], expiresAt: .integer(1_800_000_000),
            recipientRoleAssignments: [.init(email: "a@example.com", roleAssignment: .init(vaultRoleName: "reader"))]
        )
        #expect(try json(payload) == [
            "vault_id": 3, "root_entry_id": 41, "root_path": "/docs", "target_type": "directory",
            "link_type": "download", "access_mode": "email_validated", "allowed_ops": ["list", "download"],
            "expires_at": 1_800_000_000,
            "recipient_role_assignments": [
                ["email": "a@example.com", "role_assignment": ["vault_role_name": "reader"]],
            ],
        ])
        let decoded = try JSONDecoder().decode(Ws.Share.Link.Create.Payload.self, from: JSONEncoder().encode(payload))
        #expect(decoded == payload)
    }

    @Test func noPayloadIsNullAndEmptyIsAnObject() throws {
        #expect(try json(WsNoPayload()) == .null)
        #expect(try json(WsEmpty()) == [:])
        #expect(Ws.Auth.Logout.Response.self == WsEmpty.self)
        #expect(Ws.Fs.Upload.Cancel.Payload.self == WsEmpty.self)
    }
}

@Suite struct JSONValueTests {
    @Test func keepsIntegersExact() throws {
        let json = Data(#"[9007199254740993, 1.5, true, null, "s"]"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value == [9_007_199_254_740_993, 1.5, true, .null, "s"])
        #expect(value.arrayValue?[0].integerValue == 9_007_199_254_740_993)
        #expect(value.arrayValue?[1].doubleValue == 1.5)
    }

    @Test func subscriptsObjects() throws {
        let value: JSONValue = ["a": ["b": "c"]]
        #expect(value["a"]?["b"]?.stringValue == "c")
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("x")["a"] == nil)
    }
}

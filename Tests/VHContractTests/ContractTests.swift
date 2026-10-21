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

/// One model's samples (Generated/ModelSamples.swift), or a merge patch's (minimal: no members).
struct ModelSample: Sendable, CustomTestStringConvertible {
    let name: String
    let minimal: String
    let full: String
    let roundTrip: @Sendable (String) throws -> (sent: JSONValue, decoded: JSONValue)

    init<T: Codable & Sendable>(_ type: T.Type, minimal: String, full: String) {
        name = String(reflecting: type).replacingOccurrences(of: "VHContract.", with: "")
        self.minimal = minimal
        self.full = full
        roundTrip = { try VHContractTests.roundTrip(T.self, $0) }
    }

    var testDescription: String { name }
}

func roundTrip<T: Codable>(_ type: T.Type, _ json: String) throws -> (sent: JSONValue, decoded: JSONValue) {
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

    @Test(arguments: modelSamples)
    func modelDecodesAndRoundTrips(sample: ModelSample) throws {
        // Required members only, then every member: each decodes and encodes back to the same JSON.
        let minimal = try sample.roundTrip(sample.minimal)
        #expect(minimal.decoded == minimal.sent)
        let full = try sample.roundTrip(sample.full)
        #expect(full.decoded == full.sent)
    }

    @Test func modelsMatchTheVendoredContract() throws {
        let contract = try vendoredContract()
        let models = try #require(contract["models"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        #expect(WsContract.modelsHash == contract["models_hash"]?.stringValue)
        let sampled = Set(modelSamples.map(\.name))
        for name in models {
            #expect(sampled.contains("WsModel.\(name)"), "\(name) has no sample")
        }
        // The rest are the merge patches of the models `partial` members name.
        #expect(modelSamples.count > models.count)
        #expect(modelSamples.allSatisfy {
            !$0.name.hasSuffix(".Patch") || sampled.contains(String($0.name.dropLast(".Patch".count)))
        })
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
            #expect(command.refusalKinds == entry["refusal_kinds"]?.arrayValue?.compactMap(\.stringValue))
            let confirmations = try #require(entry["confirmations"]?.arrayValue).map {
                WsConfirmation(code: $0["code"]?.stringValue ?? "", acceptField: $0["accept_field"]?.stringValue,
                               summary: $0["description"]?.stringValue ?? "")
            }
            #expect(command.confirmations == confirmations)
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
            accessMode: .emailValidated, allowedOps: .array([.list, .download]),
            expiresAt: .value(.integer(1_800_000_000)),
            recipientRoleAssignments: .value([
                .init(email: "a@example.com", roleAssignment: .init(vaultRoleName: .value("reader"))),
            ])
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

    @Test func mergePatchTellsAbsentFromNull() throws {
        // email.config.update: only the members set are sent, at any depth; `.null` clears a nullable one.
        let payload = Ws.Email.Config.Update.Payload(
            email: .init(replyTo: .null, baseURL: .value("https://vh.example"), resend: .init(endpoint: "https://r"))
        )
        #expect(try json(payload) == [
            "email": ["reply_to": .null, "base_url": "https://vh.example", "resend": ["endpoint": "https://r"]],
        ])
        #expect(try json(WsModel.EmailConfig.Patch()) == [:])
        let decoded = try JSONDecoder().decode(Ws.Email.Config.Update.Payload.self, from: JSONEncoder().encode(payload))
        #expect(decoded == payload)
        #expect(decoded.email?.replyTo == .null && decoded.email?.from == nil)
    }

    @Test func noPayloadIsNullAndEmptyIsAnObject() throws {
        #expect(try json(WsNoPayload()) == .null)
        #expect(try json(WsEmpty()) == [:])
        #expect(Ws.Auth.Logout.Response.self == WsEmpty.self)
        #expect(Ws.Fs.Upload.Cancel.Payload.self == WsEmpty.self)
    }
}

@Suite struct ModelTests {
    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func sample(_ name: String) throws -> JSONValue {
        let sample = try #require(modelSamples.first { $0.name == name })
        return try JSONDecoder().decode(JSONValue.self, from: Data(sample.full.utf8))
    }

    @Test func nestedModelsRoundTrip() throws {
        let group = WsModel.Group(
            id: 4, name: "ops", description: nil, createdAt: "2026-10-20 12:00:00",
            members: [
                .init(user: .init(id: 1, name: "ada", isActive: true), joinedAt: "2026-10-20 12:00:00"),
                .init(user: nil, joinedAt: "2026-10-21 08:00:00"),
            ]
        )
        let decoded = try decode(WsModel.Group.self, try JSONDecoder().decode(JSONValue.self,
                                                                             from: JSONEncoder().encode(group)))
        #expect(decoded == group)

        // A model nested three deep (User -> VaultRole -> Permission) inside a union, from the generated sample.
        let user = try decode(WsModel.User.self, try sample("WsModel.User"))
        guard case .array(let roles) = user.vaultRoles else {
            Issue.record("vault_roles decoded as \(user.vaultRoles)")
            return
        }
        #expect(roles.first?.permissions.isEmpty == false)
        let again = try decode(WsModel.User.self, try JSONDecoder().decode(JSONValue.self,
                                                                          from: JSONEncoder().encode(user)))
        #expect(again == user)
    }

    @Test func unionsTryTheirAlternativesInOrder() throws {
        typealias VaultID = Ws.S3.Gateway.Credentials.Create.Payload.VaultID
        let ids = try decode([VaultID].self, [3, ["vault_id": 4], ["id": 5]])
        #expect(ids == [.integer(3), .vaultID(.init(vaultID: 4)), .id(.init(id: 5))])
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ids))
        #expect(encoded == [3, ["vault_id": 4], ["id": 5]])
        #expect(throws: DecodingError.self) { try decode(VaultID.self, "seven") }

        // User.vault_roles: an array of roles, or an (empty) object.
        var user = try sample("WsModel.User").objectValue ?? [:]
        user["vault_roles"] = [:]
        #expect(try decode(WsModel.User.self, .object(user)).vaultRoles == .object([:]))
    }

    @Test func mapsAreDictionaries() throws {
        var stats = try sample("WsModel.ConnectionStats").objectValue ?? [:]
        stats["sessions_by_mode"] = ["human": 2, "share": 1]
        let decoded = try decode(WsModel.ConnectionStats.self, .object(stats))
        #expect(decoded.sessionsByMode == ["human": 2, "share": 1])
    }

    @Test func toleratesUnknownMembersAndEnumValues() throws {
        // A newer daemon: a member this build doesn't know, and a vault type it doesn't either.
        var vault = try sample("WsModel.Vault").objectValue ?? [:]
        vault["type"] = "glacier"
        vault["added_later"] = ["anything": [1, 2]]
        let decoded = try decode(WsModel.Vault.self, .object(vault))
        #expect(decoded.type == "glacier")
        #expect(!WsModel.Vault.TypeValue.allValues.contains(decoded.type))
        #expect(WsModel.Vault.TypeValue.allValues == [WsModel.Vault.TypeValue.local, WsModel.Vault.TypeValue.s3])

        var stats = try sample("WsModel.ConnectionStats").objectValue ?? [:]
        stats["status"] = "degraded"
        #expect(try decode(WsModel.ConnectionStats.self, .object(stats)).status == "degraded")
    }

    @Test func responseModelIsTheModel() {
        #expect(Ws.Sync.Conflicts.Summary.Response.self == WsModel.SyncConflictSummary.self)
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

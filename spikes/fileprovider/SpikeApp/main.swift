// THROWAWAY SPIKE (vaulthalla/desktop#2). The "app": a command runner launched from a shell.
//   VaulthallaSpike <command> [args]
import FileProvider
import Foundation
import Security
import VHContract
import VHCore
import VHIdentity
import VHNodes
import VHTransport

let store = DeviceIdentityStore(configuration: .init(
    namespace: Spike.keyNamespace, accessGroup: Spike.keychainGroup, keychain: .dataProtection))

func runSSH(_ command: [String]) throws -> String {
    let line = command.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "dev", line]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard p.terminationStatus == 0 else { throw SpikeError("ssh \(command) exited \(p.terminationStatus): \(text)") }
    return text
}

func command(_ args: [String]) async throws {
    if try await Domains.run(args) { return }
    switch args.first {
    case "info":
        Spike.log("container: \(Spike.container?.path ?? "nil")")
        let (status, value, group) = Spike.readSecret()
        Spike.log("secret read: \(Spike.describe(status)) value=\(value ?? "nil") group=\(group ?? "nil")")
        if let identity = try await store.identity(for: Spike.nodeTag) {
            Spike.log("identity: \(identity) backend=\(identity.backend.rawValue)")
        } else {
            Spike.log("identity: none")
        }
    case "put-secret":
        let value = "spike-\(UUID().uuidString.prefix(8))"
        let status = Spike.putSecret(value)
        Spike.log("put secret in \(Spike.keychainGroup): \(Spike.describe(status)) value=\(value)")
        try Data(value.utf8).write(to: Spike.container!.appending(path: "expected-secret.txt"))
    case "delete-secret":
        Spike.log("delete secret: \(Spike.describe(Spike.deleteSecret()))")
    case "create-key":
        try await store.deleteIdentity(for: Spike.nodeTag)
        let identity = try await store.createIdentity(
            for: Spike.nodeTag, deviceName: "FP Spike Mac", backend: .secureEnclave)
        Spike.log("created \(identity) backend=\(identity.backend.rawValue)")
        dumpKeyAttributes()
    case "key-attrs":
        dumpKeyAttributes()
    case "delete-key":
        try await store.deleteIdentity(for: Spike.nodeTag)
        Spike.log("deleted identity; now \(String(describing: try await store.identity(for: Spike.nodeTag)))")
    case "pair":
        try await pair(endpoint: NodeEndpoint(parsing: args[1])!)
    case "probe":
        try probeIdentity()
    case "self-test":
        try await selfTest()
    default:
        Spike.log("unknown command \(args)")
    }
}

func dumpKeyAttributes() {
    let query: [CFString: Any] = [
        kSecClass: kSecClassKey, kSecUseDataProtectionKeychain: true,
        kSecAttrApplicationTag: Data("\(Spike.keyNamespace)/\(Spike.nodeTag)".utf8),
        kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    for attrs in (result as? [[CFString: Any]]) ?? [] {
        Spike.log("key: agrp=\(attrs[kSecAttrAccessGroup] ?? "-") tkid=\(attrs[kSecAttrTokenID] ?? "-") pdmn=\(attrs[kSecAttrAccessible] ?? "-") label=\(attrs[kSecAttrLabel] ?? "-") acl=\(attrs[kSecAttrAccessControl].map { String(describing: $0) } ?? "-")")
    }
    Spike.log("key query status \(Spike.describe(status))")
}

func pair(endpoint: NodeEndpoint) async throws {
    guard let identity = try await store.identity(for: Spike.nodeTag) else { throw SpikeError("create-key first") }
    Spike.log("pairing \(identity) with \(endpoint)")
    _ = try runSSH(["/tmp/vhi_interop/vh", "device", "pair"])
    let client = PairingClient(identity: identity, configuration: .init(
        endpoint: endpoint, deviceName: "FP Spike Mac", appVersion: "0.0.0-fpspike"))
    var approvedState: PairingClient.State?
    for await state in client.start() {
        Spike.log("pairing state: \(state)")
        if case .awaitingApproval(let code) = state {
            let pending = try runSSH(["/tmp/vhi_interop/vh", "device", "pending", "--json"])
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(pending.utf8))
            guard let request = json["requests"]?.arrayValue?.first(where: {
                $0["device_id"]?.stringValue == identity.deviceID
            }), let requestID = request["request_id"]?.stringValue else { throw SpikeError("no pending request: \(pending)") }
            let choices = request["code_choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
            Spike.log("code \(code.digits), daemon choices \(choices)")
            _ = try runSSH(["/tmp/vhi_interop/vh", "device", "approve", requestID, "--code", code.digits])
        }
        if state.isFinal { approvedState = state; break }
    }
    guard case .approved(let nodeID, let nodeName, let deviceID, let serverSPKI) = approvedState else {
        throw SpikeError("pairing ended \(String(describing: approvedState))")
    }
    let status = try runSSH(["cat", "/tmp/vhi_interop/status.json"])
    let vault = try JSONDecoder().decode(JSONValue.self, from: Data(status.utf8))["vault_id"]?.integerValue ?? 0
    try Spike.saveConfig(.init(host: endpoint.host, port: endpoint.port, serverSPKIHex: serverSPKI.hex,
                               vaultID: Int64(vault), deviceID: deviceID))
    Spike.log("paired: node \(nodeName) (\(nodeID)) device \(deviceID) pin \(serverSPKI.hex); vault \(vault); config saved")
}

func selfTest() async throws {
    let config = try Spike.loadConfig()
    guard let identity = try await store.identity(for: Spike.nodeTag) else { throw SpikeError("no identity") }
    let endpoint = NodeEndpoint(host: config.host, port: config.port)
    let pin = Data(hexString: config.serverSPKIHex)
    let ws = try WsClient(configuration: .init(endpoint: endpoint, security: .mutualTLS(
        identity: identity.secIdentity, serverSPKIPin: pin, onServerSPKI: { _ in })))
    let listing = try await ws.send(Ws.Fs.Dir.List.self, payload: .init(vaultID: config.vaultID, path: "/"))
    Spike.log("app fs.dir.list /: \(listing.files.map { "\($0.name)(\($0.type),\($0.sizeBytes))" })")
    await ws.close()
    let http = try DeviceHTTPClient(configuration: .init(endpoint: endpoint, identity: identity.secIdentity, serverSPKIPin: pin))
    let (data, response) = try await http.download(vaultID: config.vaultID, path: "/hello.txt")
    Spike.log("app GET /hello.txt: \(response.statusCode) \(data.count) bytes")
    http.invalidate()
}

let args = Array(CommandLine.arguments.dropFirst())
Task {
    do {
        try await command(args)
        exit(0)
    } catch {
        Spike.log("FAILED \(args): \(error)")
        exit(1)
    }
}
dispatchMain()

// THROWAWAY SPIKE (vaulthalla/desktop#2). The extension's connection to the paired node: the Secure Enclave
// identity from the shared keychain group, fs.dir.list over /ws, and /download/content over HTTPS.
import Foundation
import VHContract
import VHCore
import VHIdentity
import VHTransport

actor Backend {
    static let shared = Backend()

    private var ws: WsClient?
    private var http: DeviceHTTPClient?
    private(set) var config: Spike.NodeConfig?
    private var entries: [String: WsModel.FsEntry] = [:]

    private func connect() async throws -> (WsClient, DeviceHTTPClient, Spike.NodeConfig) {
        if let ws, let http, let config { return (ws, http, config) }
        let config = try Spike.loadConfig()
        let store = DeviceIdentityStore(configuration: .init(
            namespace: Spike.keyNamespace, accessGroup: Spike.keychainGroup, keychain: .dataProtection))
        guard let identity = try await store.identity(for: Spike.nodeTag) else {
            throw SpikeError("the extension found no identity in \(Spike.keychainGroup)")
        }
        Spike.log("ext identity: \(identity) backend=\(identity.backend.rawValue) matches pairing=\(identity.deviceID == config.deviceID)")
        let endpoint = NodeEndpoint(host: config.host, port: config.port)
        let pin = Data(hexString: config.serverSPKIHex)
        let ws = try WsClient(configuration: .init(endpoint: endpoint, security: .mutualTLS(
            identity: identity.secIdentity, serverSPKIPin: pin, onServerSPKI: { _ in })))
        let http = try DeviceHTTPClient(configuration: .init(
            endpoint: endpoint, identity: identity.secIdentity, serverSPKIPin: pin, timeout: .seconds(120)))
        self.ws = ws
        self.http = http
        self.config = config
        return (ws, http, config)
    }

    func list(_ path: String) async throws -> [WsModel.FsEntry] {
        let (ws, _, config) = try await connect()
        let started = Date()
        let listing = try await ws.send(Ws.Fs.Dir.List.self, payload: .init(vaultID: config.vaultID, path: path))
        Spike.log("ext fs.dir.list \(path): \(listing.files.count) entries in \(ms(started)) ms: \(listing.files.map(\.name))")
        for entry in listing.files { entries[entry.path] = entry }
        return listing.files
    }

    func entry(_ path: String) async throws -> WsModel.FsEntry? {
        if let cached = entries[path] { return cached }
        let parent = (path as NSString).deletingLastPathComponent
        _ = try await list(parent.isEmpty ? "/" : parent)
        return entries[path]
    }

    func download(_ path: String, range: ClosedRange<Int64>? = nil) async throws -> (Data, Int) {
        let (_, http, config) = try await connect()
        let started = Date()
        let (data, response) = try await http.download(vaultID: config.vaultID, path: path, range: range)
        Spike.log("ext GET /download/content \(path) range=\(range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none") -> \(response.statusCode) \(data.count) bytes in \(ms(started)) ms content-range=\(response.value(forHTTPHeaderField: "Content-Range") ?? "-")")
        return (data, response.statusCode)
    }

    private func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
}

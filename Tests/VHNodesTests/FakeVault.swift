import Foundation
import Network
import Synchronization
import VHContract
import VHIdentity

/// One vault as the daemon serves it to a Device session, for the File Provider replica's tests (vaulthalla/desktop#4):
/// the `fs.*` commands on the ``MockDaemon`` and the HTTP lanes on an ``HTTPTestServer`` (`/download/content` with
/// `Range` and `If-Range`, `PUT /upload/content` with its preconditions, `/preview/batch`, `/preview`).
///
/// Entries carry the versions vaulthalla/server#257 adds: `content_version` (a strong ETag, `"g<id>-<generation>"`,
/// files only, bumped by every content write) and `metadata_version` (`m<id>-<revision>`, bumped by renames, moves and
/// writes). Ids survive renames and moves. Deletes go to a trash, as the server's do.
final class FakeVault: Sendable {
    static let vaultID: Int64 = 3

    struct Entry: Sendable {
        var id: Int64
        var parent: Int64?
        var name: String
        var type: String
        var data = Data()
        var generation = 1
        var revision = 1
        var target: String?
    }

    struct State {
        var entries: [Int64: Entry] = [1: Entry(id: 1, parent: nil, name: "Vault", type: "directory")]
        var nextID: Int64 = 100
        var trash: [Entry] = []
        /// Paths whose listing the account may not see (`fs.dir.list` refuses "denied").
        var unlistable: Set<String> = []
        /// Paths the account may not write (uploads 403, commands "denied").
        var readOnly: Set<String> = []
        /// Run before a `PUT /upload/content` is answered: a competing write that lands between the replica's check
        /// and its upload.
        var beforePut: (@Sendable (inout State) -> Void)?
        var puts: [(path: String, ifMatch: String?, ifNoneMatch: String?)] = []
    }

    let state = Mutex(State())

    // MARK: Building

    @discardableResult
    func add(_ path: String, data: Data? = nil, type: String? = nil, target: String? = nil) -> Int64 {
        state.withLock { state in
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent = Self.lookup(parentPath, in: state)!.id
            let id = state.nextID
            state.nextID += 1
            state.entries[id] = Entry(id: id, parent: parent, name: (path as NSString).lastPathComponent,
                                      type: type ?? (data == nil ? "directory" : "file"), data: data ?? Data(),
                                      target: target)
            return id
        }
    }

    /// Someone else edits the file on the server.
    func edit(_ path: String, _ data: Data) {
        state.withLock { state in
            guard let id = Self.lookup(path, in: state)?.id else { return }
            state.entries[id]!.data = data
            state.entries[id]!.generation += 1
            state.entries[id]!.revision += 1
        }
    }

    func remove(_ path: String) {
        state.withLock { state in
            if let id = Self.lookup(path, in: state)?.id { Self.trash(id, in: &state) }
        }
    }

    func data(_ path: String) -> Data? {
        state.withLock { Self.lookup(path, in: $0).map(\.data) }
    }

    func id(_ path: String) -> Int64? {
        state.withLock { Self.lookup(path, in: $0)?.id }
    }

    func names(in path: String) -> [String] {
        state.withLock { state in
            guard let folder = Self.lookup(path, in: state) else { return [] }
            return state.entries.values.filter { $0.parent == folder.id }.map(\.name).sorted()
        }
    }

    func contentVersion(_ path: String) -> String? {
        state.withLock { Self.lookup(path, in: $0).map { "\"g\($0.id)-\($0.generation)\"" } }
    }

    // MARK: Lookups

    static func path(of id: Int64, in state: State) -> String {
        var parts: [String] = []
        var current = state.entries[id]
        while let entry = current, let parent = entry.parent {
            parts.insert(entry.name, at: 0)
            current = state.entries[parent]
        }
        return "/" + parts.joined(separator: "/")
    }

    static func lookup(_ path: String, in state: State) -> Entry? {
        var current = state.entries[1]!
        for part in path.split(separator: "/") where !part.isEmpty {
            guard let next = state.entries.values.first(where: { $0.parent == current.id && $0.name == part }) else {
                return nil
            }
            current = next
        }
        return current
    }

    static func trash(_ id: Int64, in state: inout State) {
        for child in state.entries.values where child.parent == id { trash(child.id, in: &state) }
        if let entry = state.entries.removeValue(forKey: id) { state.trash.append(entry) }
    }

    static func json(_ entry: Entry, in state: State, base: Bool = false) -> JSONValue {
        var object: JSONObject = [
            "id": .integer(entry.id), "name": .string(entry.name), "path": .string(path(of: entry.id, in: state)),
            "abs_path": .string("/mnt/vault" + path(of: entry.id, in: state)),
            "size_bytes": .integer(Int64(entry.data.count)), "is_hidden": .bool(entry.name.hasPrefix(".")),
            "is_system": false, "created_at": "2026-10-01T08:00:00Z",
            "updated_at": .string("2026-10-24T12:\(String(format: "%02d", entry.revision % 60)):00Z"),
            "vault_id": .integer(vaultID), "metadata_version": .string("m\(entry.id)-\(entry.revision)"),
        ]
        if let parent = entry.parent { object["parent_id"] = .integer(parent) }
        if entry.type == "file" { object["content_version"] = .string("\"g\(entry.id)-\(entry.generation)\"") }
        if !base {
            object["type"] = .string(entry.type)
            if entry.type == "file" { object["mime_type"] = .null }
            if entry.type == "symlink" { object["target"] = .string(entry.target ?? "") }
        }
        return .object(object)
    }

    // MARK: ws

    /// Answers the `fs.*` commands on `daemon`'s Device sessions.
    func serve(on daemon: MockDaemon) {
        daemon.answer("fs.dir.list") { payload in self.list(payload) }
        daemon.answer("fs.metadata") { payload in self.metadata(payload) }
        daemon.answer("fs.dir.create") { payload in self.mkdir(payload) }
        daemon.answer("fs.entry.rename") { payload in self.move(payload) }
        daemon.answer("fs.entry.move") { payload in self.move(payload) }
        daemon.answer("fs.entry.delete") { payload in self.delete(payload) }
    }

    private func list(_ payload: JSONValue) -> MockDaemon.Reply {
        state.withLock { state in
            let path = payload["path"]?.stringValue ?? "/"
            if state.unlistable.contains(path) { return .refuse("Permission denied", code: "denied") }
            guard let folder = Self.lookup(path, in: state), folder.type == "directory" else {
                return .refuse("Not found", code: "not_found")
            }
            let children = state.entries.values.filter { $0.parent == folder.id }.sorted { $0.name < $1.name }
            return .ok(["vault": "Vault", "path": .string(path), "entry": Self.json(folder, in: state, base: true),
                        "files": .array(children.map { Self.json($0, in: state) })])
        }
    }

    private func metadata(_ payload: JSONValue) -> MockDaemon.Reply {
        state.withLock { state in
            let path = payload["path"]?.stringValue ?? "/"
            guard let entry = Self.lookup(path, in: state) else { return .refuse("Not found", code: "not_found") }
            return .ok(["vault": "Vault", "path": .string(path), "entry": Self.json(entry, in: state, base: true)])
        }
    }

    private func mkdir(_ payload: JSONValue) -> MockDaemon.Reply {
        state.withLock { state in
            guard let path = payload["path"]?.stringValue else { return .refuse("Malformed", code: "invalid") }
            let parentPath = (path as NSString).deletingLastPathComponent
            if state.readOnly.contains(parentPath) { return .refuse("Permission denied", code: "denied") }
            guard let parent = Self.lookup(parentPath, in: state) else { return .refuse("Not found", code: "not_found") }
            if Self.lookup(path, in: state) != nil { return .refuse("Already exists", code: "conflict") }
            let id = state.nextID
            state.nextID += 1
            state.entries[id] = Entry(id: id, parent: parent.id, name: (path as NSString).lastPathComponent,
                                      type: "directory")
            return .ok(["path": .string(path)])
        }
    }

    private func move(_ payload: JSONValue) -> MockDaemon.Reply {
        state.withLock { state in
            guard let from = payload["from"]?.stringValue, let to = payload["to"]?.stringValue else {
                return .refuse("Malformed", code: "invalid")
            }
            guard let entry = Self.lookup(from, in: state) else { return .refuse("Not found", code: "not_found") }
            let parentPath = (to as NSString).deletingLastPathComponent
            if state.readOnly.contains(parentPath) { return .refuse("Permission denied", code: "denied") }
            guard let parent = Self.lookup(parentPath, in: state) else { return .refuse("Not found", code: "not_found") }
            if Self.lookup(to, in: state) != nil { return .refuse("Already exists", code: "conflict") }
            state.entries[entry.id]!.parent = parent.id
            state.entries[entry.id]!.name = (to as NSString).lastPathComponent
            state.entries[entry.id]!.revision += 1
            return .ok(["from": .string(from), "to": .string(to)])
        }
    }

    private func delete(_ payload: JSONValue) -> MockDaemon.Reply {
        state.withLock { state in
            guard let path = payload["path"]?.stringValue, let entry = Self.lookup(path, in: state) else {
                return .refuse("Not found", code: "not_found")
            }
            if state.readOnly.contains(path) { return .refuse("Permission denied", code: "denied") }
            Self.trash(entry.id, in: &state)
            return .ok(["path": .string(path)])
        }
    }

    // MARK: HTTP

    func handle(_ request: HTTPTestServer.Request) -> HTTPTestServer.Response {
        let components = URLComponents(string: "https://vault\(request.target)")
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch (request.method, components?.path) {
        case ("GET", "/download/content"): return download(request, path: query["path"] ?? "/")
        case ("PUT", "/upload/content"): return upload(request, path: query["path"] ?? "/")
        case ("POST", "/preview/batch"): return previewBatch(request)
        case ("GET", "/preview"):
            return .init(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        default: return .init(status: 404)
        }
    }

    private static func json(_ status: Int, _ object: JSONObject, etag: String? = nil) -> HTTPTestServer.Response {
        var headers = ["Content-Type": "application/json"]
        if let etag { headers["ETag"] = etag }
        return .init(status: status, headers: headers, body: (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data())
    }

    private func download(_ request: HTTPTestServer.Request, path: String) -> HTTPTestServer.Response {
        guard let entry = state.withLock({ Self.lookup(path, in: $0) }), entry.type == "file" else {
            return .init(status: 404)
        }
        let etag = "\"g\(entry.id)-\(entry.generation)\""
        let body = entry.data
        var headers = ["Content-Type": "application/octet-stream", "ETag": etag, "Accept-Ranges": "bytes"]
        guard let range = request.header("Range"), request.header("If-Range").map({ $0 == etag }) ?? true else {
            return .init(status: 200, headers: headers, body: body)
        }
        let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int(bounds.first ?? ""), start < body.count else {
            return .init(status: 416, headers: ["Content-Range": "bytes */\(body.count)"])
        }
        let end = min(Int(bounds.count > 1 ? bounds[1] : "") ?? body.count - 1, body.count - 1)
        headers["Content-Range"] = "bytes \(start)-\(end)/\(body.count)"
        return .init(status: 206, headers: headers, body: body[start...end])
    }

    private func upload(_ request: HTTPTestServer.Request, path: String) -> HTTPTestServer.Response {
        let ifMatch = request.header("If-Match")
        let ifNoneMatch = request.header("If-None-Match")
        return state.withLock { state in
            state.puts.append((path, ifMatch, ifNoneMatch))
            if let race = state.beforePut {
                state.beforePut = nil
                race(&state)
            }
            guard (ifMatch != nil) != (ifNoneMatch == "*") else {
                return Self.json(428, ["error": "Send If-Match or If-None-Match: *", "code": "precondition_required"])
            }
            let parentPath = (path as NSString).deletingLastPathComponent
            if state.readOnly.contains(parentPath) || state.readOnly.contains(path) { return .init(status: 403) }
            let existing = Self.lookup(path, in: state)
            if let existing, existing.type != "file" {
                return Self.json(409, ["error": "Something that is not a file exists at that path", "code": "conflict"])
            }
            var id: Int64
            var created = false
            if let ifMatch {
                guard let existing else { return Self.json(404, ["error": "Not found", "code": "not_found"]) }
                let current = "\"g\(existing.id)-\(existing.generation)\""
                guard ifMatch == current else {
                    return Self.json(412, ["error": "The file changed since that version", "code": "conflict",
                                           "content_version": .string(current)], etag: current)
                }
                id = existing.id
                state.entries[id]!.data = request.body
                state.entries[id]!.generation += 1
                state.entries[id]!.revision += 1
            } else {
                if let existing {
                    let current = "\"g\(existing.id)-\(existing.generation)\""
                    return Self.json(412, ["error": "The file already exists", "code": "conflict",
                                           "content_version": .string(current)], etag: current)
                }
                guard let parent = Self.lookup(parentPath, in: state) else {
                    return Self.json(404, ["error": "Not found", "code": "not_found"])
                }
                id = state.nextID
                state.nextID += 1
                state.entries[id] = Entry(id: id, parent: parent.id, name: (path as NSString).lastPathComponent,
                                          type: "file", data: request.body)
                created = true
            }
            let entry = state.entries[id]!
            let etag = "\"g\(entry.id)-\(entry.generation)\""
            return Self.json(created ? 201 : 200, ["created": .bool(created), "entry": Self.json(entry, in: state)],
                             etag: etag)
        }
    }

    private func previewBatch(_ request: HTTPTestServer.Request) -> HTTPTestServer.Response {
        let body = (try? JSONDecoder().decode(JSONValue.self, from: request.body)) ?? .null
        let items = (body["items"]?.arrayValue ?? []).map { item -> JSONValue in
            let path = item["path"]?.stringValue ?? ""
            let status = path.hasSuffix(".jpg") ? "ready" : path.hasSuffix(".png") ? "queued" : "unsupported"
            return ["key": item["key"] ?? .null, "status": .string(status)]
        }
        return Self.json(200, ["size": body["size"] ?? 256, "items": .array(items)])
    }

    // MARK: TLS

    /// The lanes' listener TLS: the daemon's key, a client certificate required and any accepted (authorization is
    /// by SPKI, as on the daemon).
    static func tls(server identity: DeviceIdentity) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_local_identity(security, sec_identity_create(identity.secIdentity)!)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) },
                                              DispatchQueue(label: "vh.test.fake-vault.tls"))
        return tls
    }
}

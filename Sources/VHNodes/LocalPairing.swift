public import Foundation
public import VHCore
import Darwin
import VHTransport

/// Pairing with the Vaulthalla server on this Mac through its own `vh` CLI (desktop#7), with the person's consent.
///
/// `vh` reaches the daemon over its Unix socket, where the daemon names the caller from the kernel's peer credentials
/// and maps that uid to a Vaulthalla user the way it always does (the account must be in the `vaulthalla` group and
/// bound to a user). Desktop never claims an identity: the window it opens belongs to whichever Vaulthalla user the
/// daemon says this macOS account is, exactly as if the person ran the commands in Terminal.
///
/// Number matching is kept, with `vh` doing the comparison over that authenticated channel:
/// 1. `vh device pair` opens a pairing window (non-interactive: it only opens it).
/// 2. Desktop pairs as usual over TLS and computes its code (docs/pairing.md §3).
/// 3. `vh device pending --json` must list a request carrying this Mac's device id, and this Mac's code must be one of
///    its three choices. Both are the daemon's own view, so a relay in between (another key on either leg) gives a
///    different code, and the request is denied rather than approved.
/// 4. `vh device approve <request> --code <code>`; the daemon checks the code once more, in constant time.
/// 5. The window is closed.
public struct LocalPairing: Sendable {
    /// What `vh` printed and how it exited.
    public struct Output: Sendable, Hashable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public init(status: Int32, stdout: String, stderr: String = "") {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }

        /// What `vh` said, for a message: stderr first, else stdout.
        var message: String {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return err.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : err
        }
    }

    /// Runs `vh` with these arguments, stdin closed.
    public typealias Runner = @Sendable (_ arguments: [String]) async throws -> Output

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// `vh` couldn't be run.
        case unavailable(String)
        /// `vh` refused, in its own words (not in the `vaulthalla` group, no user bound to this account, another
        /// user's window open, …).
        case refused(String)
        /// No request from this Mac is waiting: the address isn't this Mac's server, or the request expired.
        case requestNotFound
        /// The server's choices don't include this Mac's code: something sits between them. The request was denied.
        case codeMismatch
        /// `vh device pending --json` answered something that isn't its JSON.
        case unreadable

        public var description: String {
            switch self {
            case .unavailable(let why): "The vh command couldn't be run: \(why)"
            case .refused(let message): message.isEmpty ? "The vh command refused." : message
            case .requestNotFound:
                "The Vaulthalla server on this Mac has no request from this Mac. The address may be another server's; pair by comparing the code instead."
            case .codeMismatch:
                "The Vaulthalla server on this Mac shows a different code, so something may sit between them. The request was denied."
            case .unreadable: "The vh command answered in a form this version can't read."
            }
        }
    }

    /// Where Vaulthalla's installers put `vh`.
    public static let installLocations = ["/usr/local/bin/vh", "/opt/homebrew/bin/vh"]

    private let run: Runner

    public init(run: @escaping Runner) {
        self.run = run
    }

    /// The `vh` on this Mac, if a Vaulthalla server is installed here.
    public static func installed(fileManager: FileManager = .default) -> URL? {
        installLocations.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }

    /// Runs the `vh` at `executable` as this process's user.
    public static func cli(at executable: URL) -> LocalPairing {
        LocalPairing { arguments in try await Self.launch(executable, arguments) }
    }

    /// The pairing window `vh device pair --json` opened (server 1.21+), with where this Mac's server listens for
    /// devices and what it is. An older `vh` only opens the window: then only the defaults are known.
    public struct Window: Sendable, Hashable {
        /// The device listener's port.
        public var port: UInt16
        /// Whether the listener is up; nil when this `vh` doesn't say.
        public var listening: Bool?
        /// The daemon's install id, the `serverNodeID` a pairing records; nil from an older `vh`.
        public var nodeID: String?
        /// The SHA-256 of the server's SPKI: the key the pairing connection must present. Learnt over `vh`'s
        /// authenticated socket, so another server is refused before anything is sent (the code still decides).
        public var serverSPKISHA256: Data?

        public init(port: UInt16 = NodeEndpoint.defaultDevicePort, listening: Bool? = nil, nodeID: String? = nil,
                    serverSPKISHA256: Data? = nil) {
            self.port = port
            self.listening = listening
            self.nodeID = nodeID
            self.serverSPKISHA256 = serverSPKISHA256
        }
    }

    /// Opens a pairing window owned by the Vaulthalla user the daemon maps this macOS account to, and says what it
    /// learnt about the server: `vh device pair --json`, or plain `vh device pair` where `vh` predates `--json`.
    @discardableResult
    public func openWindow() async throws(Failure) -> Window {
        let output: Output
        do {
            output = try await vh(["device", "pair", "--json"])
        } catch .refused(let message) where message.contains("unknown option '--json'") {
            try await vh(["device", "pair"])
            return Window()
        }
        guard let opened = try? JSONDecoder().decode(Opened.self, from: Data(output.stdout.utf8)),
              let port = UInt16(exactly: opened.port), port > 0 else { throw .unreadable }
        var spki: Data?
        if let hex = opened.server_spki_sha256 {
            guard let bytes = PairLink.hex32(hex) else { throw .unreadable }
            spki = bytes
        }
        return Window(port: port, listening: opened.listening, nodeID: opened.node_id, serverSPKISHA256: spki)
    }

    /// Approves this Mac's request, once the daemon's own view confirms it: a request with `deviceID` whose choices
    /// include `code` (six digits). A request whose choices don't is denied.
    public func approve(deviceID: String, code: String) async throws(Failure) {
        let output = try await vh(["device", "pending", "--json"])
        guard let pending = try? JSONDecoder().decode(Pending.self, from: Data(output.stdout.utf8)) else {
            throw .unreadable
        }
        guard let request = pending.requests.first(where: { $0.device_id.lowercased() == deviceID.lowercased() }) else {
            throw .requestNotFound
        }
        guard request.code_choices.contains(code) else {
            _ = try? await vh(["device", "deny", request.request_id])
            throw .codeMismatch
        }
        try await vh(["device", "approve", request.request_id, "--code", code])
    }

    /// Closes this account's pairing window, if one is open. Failures are ignored: the window expires on its own.
    public func closeWindow() async {
        _ = try? await vh(["device", "pair", "--close"])
    }

    /// Whether `host` names this Mac: loopback, this Mac's host name (with or without `.local`), or one of the
    /// addresses of its interfaces. Offered only then, and still verified by step 3.
    public static func isThisMac(_ host: String, hostNames: [String] = Self.hostNames(),
                                 addresses: Set<String> = Self.interfaceAddresses()) -> Bool {
        func plain(_ name: String) -> String {
            var name = name.lowercased()
            if name.hasSuffix(".") { name.removeLast() }
            if name.hasSuffix(".local") { name.removeLast(".local".count) }
            return name
        }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if TransportSecurity.isLoopback(bare) || bare == "localhost" || addresses.contains(bare) { return true }
        return !bare.isEmpty && hostNames.map(plain).contains(plain(bare))
    }

    /// This Mac's host name (`gethostname`, which never waits on DNS as `ProcessInfo.hostName` may).
    public static func hostNames() -> [String] {
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, name.count) == 0 else { return [] }
        let text = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? [] : [text]
    }

    public static func interfaceAddresses() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.insert(text.split(separator: "%").first.map(String.init)?.lowercased() ?? text) // drop the zone
        }
        return result
    }

    // MARK: - Machinery

    /// `vh device pair --json`, the members used here.
    private struct Opened: Decodable {
        let port: Int
        let listening: Bool?
        let node_id: String?
        let server_spki_sha256: String?
    }

    /// `vh device pending --json`, the members used here.
    private struct Pending: Decodable {
        struct Request: Decodable {
            let request_id: String
            let device_id: String
            let code_choices: [String]
        }
        let requests: [Request]
    }

    @discardableResult
    private func vh(_ arguments: [String]) async throws(Failure) -> Output {
        let output: Output
        do {
            output = try await run(arguments)
        } catch {
            throw .unavailable(String(describing: error))
        }
        guard output.status == 0 else { throw .refused(output.message) }
        return output
    }

    private static func launch(_ executable: URL, _ arguments: [String]) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice // no terminal: `vh` never prompts
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Cancelling the caller (a timeout) stops a `vh` that hangs, say on a wedged daemon; it then reports how it
        // ended like any other run.
        return try await withTaskCancellationHandler {
            try await run(process, stdout: stdout, stderr: stderr)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func run(_ process: Process, stdout: Pipe, stderr: Pipe) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            // `vh` prints a few lines at most, well under a pipe's buffer, so reading after it exits can't stall it.
            process.terminationHandler = { finished in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: Output(status: finished.terminationStatus,
                                                      stdout: String(decoding: out, as: UTF8.self),
                                                      stderr: String(decoding: err, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

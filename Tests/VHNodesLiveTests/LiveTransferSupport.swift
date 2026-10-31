import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
import VHIdentity
import VHNodes
import VHTransport

// Support for the direct-transport live tests (LiveTransferTests, LiveTransferBenchmarks): a paired device, the box's
// side (`vh fs get`, the instance script, daemon samples), large local files, and a byte-counting TCP relay that can
// drop the route on demand.

extension LiveNode {
    /// The instance script on the box (`tools/interop/vh-instance.sh` as copied there), for `restart`.
    static let script = ProcessInfo.processInfo.environment["VH_LIVE_SCRIPT"] ?? "~/work/vh-instance.sh"

    /// A command line run by the box's shell as is (pipes and redirections allowed). Only fixed text and numbers go in.
    @discardableResult
    static func shell(_ line: String) async throws -> String {
        try await run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", sshDestination, line])
    }

    /// SHA-256 (hex) of a vault file as the node serves it to `vh fs get` (the CLI's own read path, as the seeded user).
    static func sha256(vault: Int64, path: String) async throws -> String {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let line = try await shell("set -o pipefail; \(runDirectory)/vh fs get \(vault) \(quoted) | sha256sum")
        return String(line.prefix(64))
    }

    /// `vh-instance.sh restart` (`--kill`: SIGKILL, a crash): the daemon stops and starts again on the same database and
    /// run directory. Returns the new status.
    static func restartDaemon(kill: Bool = false) async throws -> Instance {
        let text = try await shell("sudo VHI_RUN=\(runDirectory) bash \(script) restart\(kill ? " --kill" : "")")
        let json = text.split(separator: "\n").last.map(String.init) ?? text
        return try JSONDecoder().decode(Instance.self, from: Data(json.utf8))
    }

    /// The daemon's pid (status.json).
    static func daemonPID() async throws -> Int {
        let text = try await remote(["cat", "\(runDirectory)/status.json"])
        struct Status: Decodable { var pid: Int }
        return try JSONDecoder().decode(Status.self, from: Data(text.utf8)).pid
    }
}

// MARK: - A paired device

/// One freshly paired key with the instance's seeded user, as the suites use it; revoked when the test ends.
struct LiveDevice: Sendable {
    let keys: DeviceKeys
    let identity: DeviceIdentity
    let tag: String
    let endpoint: NodeEndpoint
    let instance: LiveNode.Instance
    let serverNodeID: String
    let nodeName: String
    let deviceID: String
    let serverSPKI: Data

    var vault: Int64 { instance.vaultID }

    /// The node record as the app would keep it after pairing, with `endpoint` as the configured address.
    func node(endpoint configured: NodeEndpoint? = nil, endpoints: [AdvertisedEndpoint] = []) -> Node {
        Node(id: NodeID(rawValue: tag), displayName: nodeName, endpoint: configured ?? endpoint,
             pairing: .paired(serverSPKISHA256: serverSPKI, deviceID: deviceID, since: .now),
             serverNodeID: serverNodeID, endpoints: endpoints)
    }

    func laneConfiguration(_ at: NodeEndpoint? = nil, timeout: Duration = .seconds(30)) -> DeviceHTTPClient.Configuration {
        DeviceHTTPClient.Configuration(endpoint: at ?? endpoint, identity: identity.secIdentity, serverSPKIPin: serverSPKI,
                                       timeout: timeout)
    }

    /// The lanes as the app builds them for a node announcing `http.upload.resumable` and `device.lanes.transfer`.
    func lanes(_ at: NodeEndpoint? = nil, tuning: TransferTuner.Configuration = TransferTuner.Configuration(),
               endpointClass: TransferEndpointClass = .lan, cache: TransferEstimateCache? = nil,
               store: ResumableStore? = nil, resumable: Bool = true,
               configure: (inout VaultLanes.Policy) -> Void = { _ in }) throws -> VaultLanes {
        var policy = VaultLanes.Policy()
        configure(&policy)
        var lanes = VaultLanes(transfers: try DeviceTransferClient(configuration: laneConfiguration(at)), policy: policy)
        lanes.features = .init(resumableUploads: resumable, transferLanes: true)
        lanes.monitor = TransferMonitor(node: serverNodeID, endpointClass: endpointClass, configuration: tuning,
                                        cache: cache)
        lanes.store = store
        return lanes
    }

    /// A request/response client on the device's trust (status, raw parts).
    func http(_ at: NodeEndpoint? = nil) throws -> DeviceHTTPClient {
        try DeviceHTTPClient(configuration: laneConfiguration(at))
    }

    /// Pairs a fresh key (approved with the code the client computed), runs `body`, and revokes the key afterwards,
    /// also when `body` fails.
    static func with<R: Sendable>(tag: String = "live-node", _ body: (LiveDevice) async throws -> R) async throws -> R {
        let endpoint = try LiveNode.requireEndpoint()
        let instance = try await LiveNode.instance()
        try #require(instance.alive, "the instance isn't running")
        return try await LiveKeychain.withKeys { keys in
            let identity = try await keys.identityForPairing(nodeTag: tag, deviceName: LiveInteropTests.deviceName,
                                                             replacingExisting: true)
            let final = try await LiveInteropTests.pair(identity, endpoint: endpoint) { code, _ in code.digits }
            guard case .approved(let serverNodeID, let nodeName, let deviceID, let serverSPKI) = final else {
                throw LiveFailure("pairing ended \(final)")
            }
            let device = LiveDevice(keys: keys, identity: identity, tag: tag, endpoint: endpoint, instance: instance,
                                    serverNodeID: serverNodeID, nodeName: nodeName, deviceID: deviceID,
                                    serverSPKI: serverSPKI)
            do {
                let result = try await body(device)
                try await device.revoke()
                return result
            } catch {
                try? await device.revoke()
                throw error
            }
        }
    }

    func revoke() async throws {
        let current = (try? await keys.identity(for: tag))?.deviceID ?? deviceID
        try await LiveNode.vh(["device", "revoke", String(current.prefix(16))])
    }
}

// MARK: - Upload sessions over HTTP

/// The resumable-upload wire (the server's transfer-protocol.md §3), for checks the uploader doesn't expose.
enum UploadWire {
    struct Status: Decodable {
        struct File: Decodable {
            var file_id: String
            var path: String
            var size: Int64
            var state: String
            var received_bytes: Int64
            var ranges: [[Int64]]
        }
        var upload_id: String
        var state: String
        var files: [File]
    }

    static func status(_ http: DeviceHTTPClient, upload: String) async throws -> (Int, Status?) {
        let request = URLRequest(url: try http.url(path: "/upload/sessions/\(upload)"))
        let (data, response) = try await http.data(for: request)
        return (response.statusCode, try? JSONDecoder().decode(Status.self, from: data))
    }

    static func create(_ http: DeviceHTTPClient, vault: Int64, files: [JSONValue]) async throws -> (Int, JSONValue?) {
        var request = URLRequest(url: try http.url(path: "/upload/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["vault_id": .integer(vault), "files": .array(files)]))
        let (data, response) = try await http.data(for: request)
        return (response.statusCode, try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    static func part(_ http: DeviceHTTPClient, upload: String, file: String, offset: Int64, bytes: Data)
        async throws -> (Int, JSONValue?)
    {
        var request = URLRequest(url: try http.url(path: "/upload/sessions/\(upload)/files/\(file)",
                                                    query: [.init(name: "offset", value: String(offset))]))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = bytes
        let (data, response) = try await http.data(for: request)
        return (response.statusCode, try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    static func finish(_ http: DeviceHTTPClient, upload: String) async throws -> (Int, JSONValue?) {
        var request = URLRequest(url: try http.url(path: "/upload/sessions/\(upload)/finish"))
        request.httpMethod = "POST"
        let (data, response) = try await http.data(for: request)
        return (response.statusCode, try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    static func cancel(_ http: DeviceHTTPClient, upload: String) async throws -> Int {
        var request = URLRequest(url: try http.url(path: "/upload/sessions/\(upload)"))
        request.httpMethod = "DELETE"
        return try await http.data(for: request).1.statusCode
    }
}

// MARK: - Local files

/// Large local files of incompressible, reproducible bytes in a folder removed afterwards.
final class LiveFiles: Sendable {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "vh-live-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// `size` bytes from a xorshift stream seeded with `seed`, written in 4 MiB chunks; returns the file and its SHA-256.
    func random(_ name: String, size: Int64, seed: UInt64) throws -> (url: URL, sha256: String) {
        let url = folder.appending(path: name)
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var state = seed | 1
        var hasher = SHA256()
        var remaining = size
        let chunk = 4 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        while remaining > 0 {
            let count = Int(min(Int64(chunk), remaining))
            buffer.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt64.self)
                for index in 0..<(count + 7) / 8 {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    words[index] = state
                }
            }
            let data = Data(buffer[0..<count])
            hasher.update(data: data)
            try handle.write(contentsOf: data)
            remaining -= Int64(count)
        }
        return (url, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - A counting relay

/// A TCP relay on 127.0.0.1 to the node's device listener: TLS goes end to end (the pins still prove the node), and the
/// relay counts the bytes each way, the connections, and can drop every connection (the route goes away) or refuse new
/// ones for a while (an outage).
final class LiveRelay: Sendable {
    private struct State {
        var up: Int64 = 0
        var down: Int64 = 0
        var connections = 0
        var sockets: Set<Int32> = []
        var refusing = false
        var closed = false
    }

    let port: UInt16
    private let listener: Int32
    private let target: NodeEndpoint
    private let state = Mutex(State())

    init(to target: NodeEndpoint) throws {
        self.target = target
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LiveFailure("relay: socket failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else { close(fd); throw LiveFailure("relay: bind/listen failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listener = fd
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "live-relay-accept"
        thread.start()
    }

    var endpoint: NodeEndpoint { NodeEndpoint(host: "127.0.0.1", port: port) }

    /// Bytes client → node and node → client so far, and the connections accepted.
    var counts: (up: Int64, down: Int64, connections: Int) {
        state.withLock { ($0.up, $0.down, $0.connections) }
    }

    /// Closes every relayed connection now (both sides see the route go away mid-request).
    func dropAll() {
        let sockets = state.withLock { state -> Set<Int32> in
            defer { state.sockets = [] }
            return state.sockets
        }
        for fd in sockets { shutdown(fd, SHUT_RDWR) }
    }

    /// While true, new connections are accepted and closed at once.
    func setRefusing(_ refusing: Bool) {
        state.withLock { $0.refusing = refusing }
    }

    func stop() {
        state.withLock { $0.closed = true }
        shutdown(listener, SHUT_RDWR)
        close(listener)
        dropAll()
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if state.withLock({ $0.closed }) { return }
                continue
            }
            let refusing = state.withLock { state -> Bool in
                if !state.refusing { state.connections += 1 }
                return state.refusing
            }
            if refusing {
                close(client)
                continue
            }
            guard let upstream = connectTarget() else {
                close(client)
                continue
            }
            state.withLock { $0.sockets.formUnion([client, upstream]) }
            var on: Int32 = 1
            for fd in [client, upstream] {
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                // A write to a side that went away is an error, not SIGPIPE for the whole test process.
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            }
            let closing = Mutex(0)
            let finish: @Sendable () -> Void = { [self] in
                let done = closing.withLock { count -> Bool in
                    count += 1
                    return count == 2
                }
                shutdown(client, SHUT_RDWR)
                shutdown(upstream, SHUT_RDWR)
                if done {
                    state.withLock { $0.sockets.subtract([client, upstream]) }
                    close(client)
                    close(upstream)
                }
            }
            let a = Thread { [self] in pump(from: client, to: upstream, upstream: true); finish() }
            let b = Thread { [self] in pump(from: upstream, to: client, upstream: false); finish() }
            a.start()
            b.start()
        }
    }

    private func connectTarget() -> Int32? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target.host, String(target.port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func pump(from source: Int32, to sink: Int32, upstream: Bool) {
        let size = 256 << 10
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = read(source, buffer, size)
            if count <= 0 { return }
            var offset = 0
            while offset < count {
                let written = write(sink, buffer + offset, count - offset)
                if written <= 0 { return }
                offset += written
            }
            state.withLock { if upstream { $0.up += Int64(count) } else { $0.down += Int64(count) } }
        }
    }
}

// MARK: - Measurements

/// This process's memory: the resident set and the footprint (what Activity Monitor shows), sampled.
enum ClientMemory {
    static func current() -> (resident: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.resident_size, info.phys_footprint)
    }
}

/// Samples this process's memory every 50 ms while running; `stop()` returns the peaks.
final class ClientSampler: Sendable {
    private final class Peaks: Sendable {
        let value = Mutex<(resident: UInt64, footprint: UInt64)>((0, 0))
    }

    private let peaks = Peaks()
    private let task = Mutex<Task<Void, Never>?>(nil)

    init() {
        let peaks = peaks
        let sampler = Task.detached {
            while !Task.isCancelled {
                let now = ClientMemory.current()
                peaks.value.withLock { $0 = (max($0.resident, now.resident), max($0.footprint, now.footprint)) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        task.withLock { $0 = sampler }
    }

    func stop() -> (resident: UInt64, footprint: UInt64) {
        task.withLock { $0?.cancel() }
        let now = ClientMemory.current()
        return peaks.value.withLock { (max($0.resident, now.resident), max($0.footprint, now.footprint)) }
    }
}

/// The daemon's CPU and memory over one run, sampled on the box every 250 ms: /proc/<pid>/stat (utime + stime) and
/// /proc/<pid>/status (VmRSS, and VmHWM after resetting it through clear_refs).
struct DaemonSampler {
    struct Summary: CustomStringConvertible {
        var cpuSeconds: Double
        var wall: Double
        var peakCPUPercent: Double
        var peakRSSMiB: Double
        var averageCPUPercent: Double { wall > 0 ? cpuSeconds / wall * 100 : 0 }
        var description: String {
            String(format: "cpu %.1fs (avg %.0f%%, peak %.0f%%), peak RSS %.0f MiB", cpuSeconds, averageCPUPercent,
                   peakCPUPercent, peakRSSMiB)
        }
    }

    let pid: Int
    let samplerPID: Int
    let file: String

    static let directory = "/tmp/vhi-live-samples"

    /// The sampling loop: `sample.sh <pid> <file>` until the pid exits or the loop is killed (the daemon is root's:
    /// `kill -0` would fail, /proc doesn't).
    static let script = """
        pid=$1; out=$2
        while [ -d /proc/$pid ]; do
          echo "$(date +%s.%N) $(awk '{print $14+$15}' /proc/$pid/stat) $(awk '/VmRSS/{print $2}' /proc/$pid/status)"
          sleep 0.25
        done > "$out"
        """

    static func start() async throws -> DaemonSampler {
        let pid = try await LiveNode.daemonPID()
        let file = "\(directory)/\(UUID().uuidString).log"
        let encoded = Data(script.utf8).base64EncodedString()
        let text = try await LiveNode.shell(
            "mkdir -p \(directory) && echo \(encoded) | base64 -d > \(directory)/sample.sh && "
                + "sudo sh -c 'echo 5 > /proc/\(pid)/clear_refs' && "
                + "(nohup bash \(directory)/sample.sh \(pid) \(file) < /dev/null > /dev/null 2>&1 & echo $!)")
        guard let sampler = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LiveFailure("sampler didn't start: \(text)")
        }
        return DaemonSampler(pid: pid, samplerPID: sampler, file: file)
    }

    func stop() async throws -> Summary {
        let text = try await LiveNode.shell(
            "kill \(samplerPID) 2>/dev/null; sleep 0.3; echo HWM $(awk '/VmHWM/{print $2}' /proc/\(pid)/status); "
                + "echo TCK $(getconf CLK_TCK); cat \(file); rm -f \(file)")
        var hwm = 0.0
        var ticksPerSecond = 100.0
        var samples: [(t: Double, ticks: Double, rss: Double)] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.first == "HWM", fields.count > 1 { hwm = Double(fields[1]) ?? 0; continue }
            if fields.first == "TCK", fields.count > 1 { ticksPerSecond = Double(fields[1]) ?? 100; continue }
            guard fields.count >= 3, let t = Double(fields[0]), let ticks = Double(fields[1]), let rss = Double(fields[2])
            else { continue }
            samples.append((t, ticks, rss))
        }
        guard let first = samples.first, let last = samples.last else {
            return Summary(cpuSeconds: 0, wall: 0, peakCPUPercent: 0, peakRSSMiB: hwm / 1024)
        }
        var peak = 0.0
        var start = 0
        for end in samples.indices {
            while samples[end].t - samples[start].t > 1.0 { start += 1 }
            let span = samples[end].t - samples[start].t
            if span >= 0.7 { peak = max(peak, (samples[end].ticks - samples[start].ticks) / ticksPerSecond / span * 100) }
        }
        let rssPeak = max(hwm, samples.map(\.rss).max() ?? 0)
        return Summary(cpuSeconds: (last.ticks - first.ticks) / ticksPerSecond, wall: last.t - first.t,
                       peakCPUPercent: peak, peakRSSMiB: rssPeak / 1024)
    }
}

/// Monotonic seconds.
func liveNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

let mib: Int64 = 1 << 20

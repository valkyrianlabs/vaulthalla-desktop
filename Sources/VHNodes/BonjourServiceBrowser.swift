public import Foundation
public import VHCore
import Network
import dnssd
import os

/// A Vaulthalla server advertising `_vaulthalla._tcp` on the local network (docs/architecture.md §2, S5).
public struct DiscoveredServer: Identifiable, Hashable, Sendable {
    /// The Bonjour service instance (name and domain), stable while it's advertised.
    public let id: String
    public var serviceName: String
    /// The node's display name from the TXT record (`name`, `display_name`), else the service name.
    public var displayName: String
    /// TXT `node_id`: the server's install id, as `device.pair.status` reports it (`Node.serverNodeID`).
    public var nodeID: String?
    /// TXT `port`: the device listener's port, when the record names it.
    public var devicePort: UInt16?
    /// Filled in once the service resolves to a host name and port (the TXT `port` wins over the service's).
    public var endpoint: NodeEndpoint?
    /// False once resolution has answered, with or without an endpoint.
    public var isResolving = true

    public init(id: String, serviceName: String, displayName: String, nodeID: String? = nil, devicePort: UInt16? = nil,
                endpoint: NodeEndpoint? = nil, isResolving: Bool = true) {
        self.id = id
        self.serviceName = serviceName
        self.displayName = displayName
        self.nodeID = nodeID
        self.devicePort = devicePort
        self.endpoint = endpoint
        self.isResolving = isResolving
    }
}

/// Browses for Vaulthalla servers with `NWBrowser` and resolves each one's host with `DNSServiceResolve`, whose host
/// name (`vh-storage.local`) outlives DHCP address changes, unlike the IP a connection would report.
///
/// Used by the Add Node sheet (continuously, while it is open) and by the endpoint selector as its last source
/// (``endpoints(forNode:within:)``, a short bounded browse). Every TXT value is untrusted: names are trimmed and
/// capped, ids and ports validated; nothing found here is used before the pinned key was proven at that address.
///
/// `@unchecked Sendable`: all state lives on the browser's serial queue.
public final class BonjourServiceBrowser: @unchecked Sendable {
    public static let serviceType = "_vaulthalla._tcp"

    public enum Status: Hashable, Sendable {
        case idle
        case browsing
        /// Local network access is off (System Settings → Privacy & Security → Local Network).
        case denied
        case failed(String)
    }

    public typealias Update = @Sendable ([DiscoveredServer], Status) -> Void

    private let queue: DispatchQueue
    private var browser: NWBrowser?
    private var resolvers: [String: ServiceResolver] = [:]
    private var servers: [DiscoveredServer] = []
    private var status: Status = .idle
    private var onUpdate: Update?
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "bonjour")

    public init(queue: DispatchQueue = DispatchQueue(label: "sh.vaulthalla.bonjour")) {
        self.queue = queue
    }

    deinit {
        browser?.cancel()
        resolvers.values.forEach { $0.cancel() }
    }

    /// Starts browsing; `onUpdate` gets the servers (sorted by name) and the status on every change, on the
    /// browser's queue.
    public func start(_ onUpdate: @escaping Update) {
        queue.async { [self] in
            guard browser == nil else { return }
            self.onUpdate = onUpdate
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let made = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
            made.stateUpdateHandler = { [weak self] state in self?.update(state) }
            made.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
            browser = made
            status = .browsing
            made.start(queue: queue)
            publish()
        }
    }

    /// Stops browsing and resolving. No update follows.
    public func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            resolvers.values.forEach { $0.cancel() }
            resolvers = [:]
            servers = []
            status = .idle
            onUpdate = nil
        }
    }

    /// Browses for `duration` and returns the resolved endpoints of the servers whose TXT `node_id` is `nodeID`.
    public static func endpoints(forNode nodeID: String, within duration: Duration) async -> [NodeEndpoint] {
        let found = await browse(for: duration) { servers in
            servers.contains { $0.nodeID == nodeID && !$0.isResolving }
        }
        return found.filter { $0.nodeID == nodeID }.compactMap(\.endpoint)
    }

    /// Browses for at most `duration` (less once `enough` says so) and returns what was found.
    public static func browse(for duration: Duration, until enough: @escaping @Sendable ([DiscoveredServer]) -> Bool = { _ in false })
        async -> [DiscoveredServer]
    {
        let browser = BonjourServiceBrowser()
        let latest = LatestServers()
        let done = AsyncStream<Void>.makeStream()
        browser.start { servers, status in
            latest.set(servers)
            if enough(servers) || status == .denied { done.continuation.yield() }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: duration) }
            group.addTask { for await _ in done.stream { return } }
            await group.next()
            group.cancelAll()
            done.continuation.finish()
        }
        browser.stop()
        return latest.get()
    }

    // MARK: - Updates (on the queue)

    private func update(_ state: NWBrowser.State) {
        switch state {
        case .ready, .setup:
            status = .browsing
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                status = .denied
            } else {
                status = .failed(error.localizedDescription)
            }
        case .cancelled:
            status = .idle
        @unknown default:
            break
        }
        publish()
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [DiscoveredServer] = []
        var seen: Set<String> = []
        var toResolve: [(id: String, name: String, type: String, domain: String, interface: UInt32)] = []

        for result in results {
            guard case .service(let name, let type, let domain, let interface) = result.endpoint else { continue }
            let id = "\(name).\(domain)"
            guard seen.insert(id).inserted else { continue }

            var txt: NWTXTRecord?
            if case .bonjour(let record) = result.metadata { txt = record }
            let advertisedName = (txt?["name"] ?? txt?["display_name"]).flatMap(Self.displayName)
            let existing = servers.first { $0.id == id }
            next.append(DiscoveredServer(
                id: id, serviceName: name, displayName: advertisedName ?? name,
                nodeID: txt?["node_id"].flatMap(Self.nodeID), devicePort: txt?["port"].flatMap(Self.port),
                endpoint: existing?.endpoint, isResolving: existing?.isResolving ?? true))

            if resolvers[id] == nil && existing == nil {
                toResolve.append((id, name, type, domain, interface.map { UInt32($0.index) } ?? 0))
            }
        }

        for (id, resolver) in resolvers where !seen.contains(id) {
            resolver.cancel()
            resolvers[id] = nil
        }
        servers = next.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        for service in toResolve {
            let resolver = ServiceResolver(queue: queue) { [weak self] endpoint in
                self?.resolved(id: service.id, endpoint: endpoint)
            }
            resolvers[service.id] = resolver
            resolver.start(name: service.name, type: service.type, domain: service.domain,
                           interfaceIndex: service.interface)
        }
        publish()
    }

    private func resolved(id: String, endpoint: NodeEndpoint?) {
        resolvers[id]?.cancel()
        resolvers[id] = nil
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        var endpoint = endpoint
        if let port = servers[index].devicePort { endpoint?.port = port }
        servers[index].endpoint = endpoint
        servers[index].isResolving = false
        publish()
    }

    private func publish() {
        onUpdate?(servers, status)
    }

    // MARK: - TXT values (untrusted)

    static func displayName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : String(trimmed.prefix(64))
    }

    static func nodeID(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !text.isEmpty, text.count <= 128, text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return text
    }

    static func port(_ text: String) -> UInt16? {
        guard let port = UInt16(text), port > 0 else { return nil }
        return port
    }
}

/// The last list a browse reported.
private final class LatestServers: Sendable {
    private let value = OSAllocatedUnfairLock<[DiscoveredServer]>(initialState: [])
    func set(_ servers: [DiscoveredServer]) { value.withLock { $0 = servers } }
    func get() -> [DiscoveredServer] { value.withLock { $0 } }
}

/// One `DNSServiceResolve` call, delivered on the browser's queue. Answers once, then the caller cancels it.
///
/// `@unchecked Sendable`: used only on that queue.
private final class ServiceResolver: @unchecked Sendable {
    private var ref: DNSServiceRef?
    private let queue: DispatchQueue
    private let completion: (NodeEndpoint?) -> Void

    init(queue: DispatchQueue, completion: @escaping (NodeEndpoint?) -> Void) {
        self.queue = queue
        self.completion = completion
    }

    func start(name: String, type: String, domain: String, interfaceIndex: UInt32) {
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = DNSServiceResolve(&ref, 0, interfaceIndex, name, type, domain, serviceResolved, context)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            completion(nil)
            return
        }
        guard DNSServiceSetDispatchQueue(ref, queue) == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            DNSServiceRefDeallocate(ref)
            completion(nil)
            return
        }
        self.ref = ref
    }

    /// Must run before the resolver is released: the callback holds an unretained pointer to it.
    func cancel() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }

    fileprivate func finish(error: DNSServiceErrorType, host: String?, port: UInt16) {
        guard ref != nil else { return }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), var host, !host.isEmpty, port > 0 else {
            completion(nil)
            return
        }
        if host.hasSuffix(".") { host.removeLast() }
        completion(NodeEndpoint(host: host, port: port))
    }
}

private func serviceResolved(
    _ ref: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ error: DNSServiceErrorType,
    _ fullName: UnsafePointer<CChar>?,
    _ hostTarget: UnsafePointer<CChar>?,
    _ port: UInt16,
    _ txtLength: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    // DNSServiceSetDispatchQueue(queue) above: the callback arrives on the browser's queue, where the resolver lives.
    Unmanaged<ServiceResolver>.fromOpaque(context).takeUnretainedValue()
        .finish(error: error, host: hostTarget.map { String(cString: $0) }, port: UInt16(bigEndian: port))
}

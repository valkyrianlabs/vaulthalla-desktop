import Foundation
import Network
import Observation
import VHCore
import dnssd

/// A Vaulthalla server advertising `_vaulthalla._tcp` on the local network.
struct DiscoveredServer: Identifiable, Hashable {
    /// The Bonjour service instance (name and domain), stable while it's advertised.
    let id: String
    var serviceName: String
    /// The node's display name from the TXT record, else the service name.
    var displayName: String
    /// Filled in once the service resolves to a host name and port.
    var endpoint: NodeEndpoint?
    /// False once resolution has answered, with or without an endpoint.
    var isResolving = true
}

/// Browses for Vaulthalla servers with `NWBrowser` and resolves each one's host with `DNSServiceResolve`, whose host
/// name (`vh-storage.local`) outlives DHCP address changes, unlike the IP a connection would report.
@Observable
final class BonjourBrowser {
    static let serviceType = "_vaulthalla._tcp"

    enum Status: Equatable {
        case idle
        case browsing
        /// Local network access is off for Vaulthalla (System Settings → Privacy & Security → Local Network).
        case denied
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var servers: [DiscoveredServer] = []

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolvers: [String: ServiceResolver] = [:]

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.update(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        self.browser = browser
        status = .browsing
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers = [:]
        servers = []
        status = .idle
    }

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
            let advertisedName = txt?["name"] ?? txt?["display_name"]
            let existing = servers.first { $0.id == id }
            next.append(
                DiscoveredServer(
                    id: id,
                    serviceName: name,
                    displayName: advertisedName.flatMap { $0.isEmpty ? nil : $0 } ?? name,
                    endpoint: existing?.endpoint,
                    isResolving: existing?.isResolving ?? true
                )
            )

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
            let resolver = ServiceResolver { [weak self] endpoint in
                self?.resolved(id: service.id, endpoint: endpoint)
            }
            resolvers[service.id] = resolver
            resolver.start(name: service.name, type: service.type, domain: service.domain, interfaceIndex: service.interface)
        }
    }

    private func resolved(id: String, endpoint: NodeEndpoint?) {
        resolvers[id]?.cancel()
        resolvers[id] = nil
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].endpoint = endpoint
        servers[index].isResolving = false
    }
}

/// One `DNSServiceResolve` call, delivered on the main queue. Answers once, then the caller cancels it.
private final class ServiceResolver {
    private var ref: DNSServiceRef?
    private let completion: (NodeEndpoint?) -> Void

    init(completion: @escaping (NodeEndpoint?) -> Void) {
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
        guard DNSServiceSetDispatchQueue(ref, .main) == DNSServiceErrorType(kDNSServiceErr_NoError) else {
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

private nonisolated func serviceResolved(
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
    // Only dereferenced on the main actor, where the resolver lives.
    nonisolated(unsafe) let resolver = context
    let host = hostTarget.map { String(cString: $0) }
    let hostPort = UInt16(bigEndian: port)
    // DNSServiceSetDispatchQueue(.main) above: the callback always arrives on the main queue.
    MainActor.assumeIsolated {
        Unmanaged<ServiceResolver>.fromOpaque(resolver).takeUnretainedValue()
            .finish(error: error, host: host, port: hostPort)
    }
}

// THROWAWAY SPIKE (vaulthalla/desktop#2). Domain management shared by the app and the agent.
import FileProvider
import Foundation

enum Domains {
    static func domain(_ id: String, name: String? = nil) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: id), displayName: name ?? id)
    }

    static func list() async throws -> [NSFileProviderDomain] {
        try await NSFileProviderManager.domains()
    }

    static func describe(_ d: NSFileProviderDomain) -> String {
        "\(d.identifier.rawValue) '\(d.displayName)' userEnabled=\(d.userEnabled) disconnected=\(d.isDisconnected) hidden=\(d.isHidden)"
    }

    /// SPIKE_TESTING_MODE=1: NSFileProviderDomainTestingModeAlwaysEnabled (needs the development-only
    /// com.apple.developer.fileprovider.testing-mode entitlement), so the domain runs without the System Settings toggle.
    static func add(_ id: String, name: String) async throws {
        let d = domain(id, name: name)
        if ProcessInfo.processInfo.environment["SPIKE_TESTING_MODE"] == "1" { d.testingModes = [.alwaysEnabled] }
        try await NSFileProviderManager.add(d)
    }

    static func remove(_ id: String) async throws {
        let all = try await list()
        guard let d = all.first(where: { $0.identifier.rawValue == id }) else { throw SpikeError("no domain \(id)") }
        try await NSFileProviderManager.remove(d)
    }

    static func removeAll() async throws {
        try await NSFileProviderManager.removeAllDomains()
    }

    static func signal(_ id: String, container: NSFileProviderItemIdentifier = .workingSet) async throws {
        let all = try await list()
        guard let d = all.first(where: { $0.identifier.rawValue == id }) else { throw SpikeError("no domain \(id)") }
        guard let manager = NSFileProviderManager(for: d) else { throw SpikeError("NSFileProviderManager(for:) returned nil") }
        try await manager.signalEnumerator(for: container)
    }

    static func userVisibleURL(_ id: String) async throws -> URL {
        let all = try await list()
        guard let d = all.first(where: { $0.identifier.rawValue == id }) else { throw SpikeError("no domain \(id)") }
        guard let manager = NSFileProviderManager(for: d) else { throw SpikeError("NSFileProviderManager(for:) returned nil") }
        return try await manager.getUserVisibleURL(for: .rootContainer)
    }

    /// Common domain subcommands; returns false if `args` isn't one.
    static func run(_ args: [String]) async throws -> Bool {
        switch args.first {
        case "list-domains":
            let all = try await list()
            Spike.log("domains: \(all.count)")
            for d in all { Spike.log("  " + describe(d)) }
        case "add-domain":
            let id = args[1], name = args.count > 2 ? args[2] : args[1]
            try await add(id, name: name)
            Spike.log("added domain \(id) '\(name)'")
            if let url = try? await userVisibleURL(id) { Spike.log("  root: \(url.path)") }
        case "add-domains":
            // add-domains <prefix> <count>
            let prefix = args[1], count = Int(args[2]) ?? 1
            for i in 1...count {
                try await add("\(prefix)-\(i)", name: "\(prefix) \(i)")
            }
            Spike.log("added \(count) domains \(prefix)-1...\(prefix)-\(count)")
        case "remove-domain":
            try await remove(args[1])
            Spike.log("removed domain \(args[1])")
        case "remove-all":
            try await removeAll()
            Spike.log("removed all domains; now \(try await list().count)")
        case "signal":
            let id = args[1]
            let started = Date()
            try await signal(id)
            Spike.log("signalEnumerator(.workingSet) on \(id) ok in \(String(format: "%.3f", Date().timeIntervalSince(started)))s")
        case "root-url":
            Spike.log("root of \(args[1]): \(try await userVisibleURL(args[1]).path)")
        default:
            return false
        }
        return true
    }
}

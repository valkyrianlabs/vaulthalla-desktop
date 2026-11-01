import Foundation
public import VHCore

/// Signing this Mac out of its nodes (desktop#7): "Sign Out", and quitting or logging out with "Keep me signed in on
/// this Mac" off. It fails closed: every node's key is deleted here and its record returns to unpaired whatever the
/// network does, so access ends even when a node can't be told.
///
/// 1. Each paired node is asked to revoke this Mac's device (`device.revoke`, in parallel, at most `revokeTimeout`
///    each). That ends the device on the server at once and closes its live sessions there. It is best effort: an
///    unreachable node keeps a device row nobody can use, because its key is gone in step 3 (a Secure Enclave key
///    can't be copied out, and a deleted one can't be brought back), and it can be revoked from the web console.
/// 2. Finder's vaults are removed (`removeDomains`), with the copies downloaded to this Mac.
/// 3. Every node is forgotten (`forget`), paired or not (an unpaired node may keep the key of an earlier attempt): its
///    session stops, its key is deleted and it returns to unpaired. The records stay, so pairing again is one step.
///    They hold nothing secret.
public enum SignOut {
    public struct Target: Hashable, Sendable {
        public var node: NodeID
        /// The device id the node knows this Mac by.
        public var deviceID: String

        public init(node: NodeID, deviceID: String) {
            self.node = node
            self.deviceID = deviceID
        }
    }

    public struct Report: Sendable {
        /// Nodes that revoked this Mac.
        public var revoked: [NodeID] = []
        /// Nodes that couldn't be told, and why. Their keys are deleted all the same.
        public var notRevoked: [NodeID: String] = [:]
        /// Why Finder's vaults couldn't be removed, if they couldn't.
        public var domainProblem: String?

        public init() {}
    }

    /// The nodes to ask: the paired ones, by the device id each knows this Mac by.
    public static func targets(_ nodes: [Node]) -> [Target] {
        nodes.compactMap { node in
            guard case .paired(_, let deviceID, _) = node.pairing else { return nil }
            return Target(node: node.id, deviceID: deviceID)
        }
    }

    public struct TimedOut: Error, CustomStringConvertible {
        public var description: String { "it didn't answer in time" }
    }

    public static func run(
        _ nodes: [Node], revokeTimeout: Duration = .seconds(5),
        revoke: @escaping @Sendable (Target) async throws -> Void,
        removeDomains: @Sendable () async throws -> Void,
        forget: (NodeID) async -> Void, isolation: isolated (any Actor)? = #isolation
    ) async -> Report {
        var report = Report()
        let targets = targets(nodes)
        await withTaskGroup(of: (NodeID, String?).self) { group in
            for target in targets {
                group.addTask {
                    do {
                        try await bounded(revokeTimeout) { try await revoke(target) }
                        return (target.node, nil)
                    } catch {
                        return (target.node, String(describing: error))
                    }
                }
            }
            for await (node, problem) in group {
                if let problem { report.notRevoked[node] = problem } else { report.revoked.append(node) }
            }
        }
        do {
            try await removeDomains()
        } catch {
            report.domainProblem = String(describing: error)
        }
        for node in nodes { await forget(node.id) }
        return report
    }

    /// Runs `body` for at most `limit`, then gives up on it: it is cancelled, but not waited for, so a call that
    /// ignores cancellation can't hold the sign-out.
    static func bounded(_ limit: Duration, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let work = Task {
                do {
                    try await body()
                    once.run { continuation.resume() }
                } catch {
                    once.run { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                once.run {
                    work.cancel()
                    continuation.resume(throwing: TimedOut())
                }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ body: () -> Void) {
            let first = lock.withLock {
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }
}

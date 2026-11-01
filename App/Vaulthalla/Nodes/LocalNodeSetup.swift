import Foundation
import os
import VHCore
import VHNodes

/// Sets up the Vaulthalla server on this Mac without a pairing code (``LocalNodeAutopair``): the `vaulthalla` cask
/// installs the server and Desktop together and opens Desktop once, and Desktop should simply show that server, already
/// connected. It tries at launch, and while it runs: again when a server gets installed (`vh` appears), and after a
/// failed attempt every ``retryInterval``. Each tick decides from the registry alone, so nothing is run once the server
/// is saved, and only the credential owner tries (it holds the keys and writes the node list).
///
/// It never runs once the person removed this Mac's server from Desktop (``LocalNodeAutopair/declinedKey``), nor with
/// "Keep me signed in" off, where quitting signs this Mac out and pairing is the person's own step.
@MainActor
final class LocalNodeSetup {
    static let tickInterval: Duration = .seconds(60)
    static let retryInterval: Duration = .seconds(600)
    static let log = Logger(subsystem: "sh.vaulthalla.app", category: "local-node")

    /// Whether the app shouldn't add this Mac's server on its own.
    static var declined: Bool {
        UserDefaults.standard.bool(forKey: LocalNodeAutopair.declinedKey) || !SignInPreferences.keepSignedIn
    }

    /// Remembers that the person removed this Mac's server, so it isn't added back.
    static func recordRemoval(of node: Node) {
        guard LocalPairing.isThisMac(node.endpoint.host) else { return }
        UserDefaults.standard.set(true, forKey: LocalNodeAutopair.declinedKey)
    }

    /// The `vh` of this Mac's server. Debug builds take `-VHDebugLocalVH <path>` instead (scripted checks against a
    /// stand-in, with `-VHDebugRegistry`).
    static func installedVH() -> URL? {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "VHDebugLocalVH") { return URL(filePath: path) }
        #endif
        return LocalPairing.installed()
    }

    static func autopair(_ vh: URL) -> LocalNodeAutopair {
        LocalNodeAutopair(local: .cli(at: vh), deviceName: PairingFlow.deviceName, appVersion: PairingFlow.appVersion)
    }

    private weak var model: AppModel?
    private var watch: Task<Void, Never>?
    private var running = false
    private var hadServer = false
    private var lastFailure: ContinuousClock.Instant?

    func start(model: AppModel) {
        guard watch == nil else { return }
        self.model = model
        watch = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func tick() {
        let vh = Self.installedVH()
        defer { hadServer = vh != nil }
        guard let vh, !running, let model, model.isCredentialOwner, let keys = model.deviceKeys else { return }
        // A server installed since the last look is tried at once; a failure waits for the retry interval.
        if hadServer, let lastFailure, ContinuousClock.now - lastFailure < Self.retryInterval { return }
        let declined = Self.declined
        guard case .pair = LocalNodeAutopair.decide(nodes: model.nodes, declined: declined,
                                                    isThisMac: { LocalPairing.isThisMac($0) }) else { return }
        running = true
        model.settingUpLocalNode = true
        let store = model.store
        Task {
            let outcome = await Self.autopair(vh).run(store: store, keys: keys, declined: declined)
            running = false
            model.settingUpLocalNode = false
            lastFailure = outcome.isFailure ? .now : nil
            Self.log.notice("\(outcome.description, privacy: .public)")
            model.loadNodes()
        }
    }
}

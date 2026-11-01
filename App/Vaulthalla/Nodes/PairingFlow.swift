import AppKit
import Foundation
import Observation
import VHCore
import VHIdentity
import VHNodes
import VHTransport

/// One pairing sheet's attempt(s): finds or creates this Mac's key for the node, runs `PairingClient`, and records
/// the outcome in the model. Try Again starts a new attempt with fresh nonces and the same key.
@Observable
final class PairingFlow {
    enum Phase: Equatable {
        case preparing
        case connecting
        case awaitingApproval(PairingCode)
        case approved(serverName: String)
        case denied
        case expired
        case failed(PairingFailure)

        var isFinished: Bool {
            switch self {
            case .preparing, .connecting, .awaitingApproval: false
            case .approved, .denied, .expired, .failed: true
            }
        }
    }

    private(set) var phase: Phase = .preparing
    /// Where the key used for this attempt lives (shown when it's a development software key).
    private(set) var backend: KeyBackend?
    /// What the server runs, once `meta.hello` said ("Vaulthalla 1.19.0 · protocol 1"); nil until then and for a
    /// server that predates it.
    private(set) var serverRelease: String?
    /// Pairing through the `vh` of the Vaulthalla server on this Mac (``LocalPairing``): running, and why it stopped.
    private(set) var approvingLocally = false
    private(set) var localProblem: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Set while this attempt pairs through this Mac's server, with the person's consent.
    @ObservationIgnored private var local: LocalPairing?
    /// The server the person agreed to pair through: Try Again keeps using it.
    @ObservationIgnored private var localConsent: LocalPairing?
    /// Closing the last attempt's pairing window, which a new attempt waits for before opening its own.
    @ObservationIgnored private var closing: Task<Void, Never>?
    /// The key this attempt presents, by its device id.
    @ObservationIgnored private var deviceID: String?
    @ObservationIgnored private var client: PairingClient?
    /// Set once this flow replaced a revoked key, so Try Again keeps the new one.
    @ObservationIgnored private var replacedKey = false

    /// The name the owner sees in the approval list.
    static var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The `vh` of a Vaulthalla server on this Mac when `node`'s address is this Mac; nil otherwise.
    static func localServer(for node: Node) -> LocalPairing? {
        guard LocalPairing.isThisMac(node.endpoint.host), let vh = LocalPairing.installed() else { return nil }
        return .cli(at: vh)
    }

    /// The person agreed to pair through this Mac's server: approve the request waiting now, or start an attempt that
    /// opens the pairing window first and approves once the code is known.
    func pairLocally(_ server: LocalPairing, node: Node, model: AppModel) {
        localProblem = nil
        localConsent = server
        if case .awaitingApproval(let code) = phase, let deviceID {
            local = server
            Task { await approveLocally(server, deviceID: deviceID, code: code) }
        } else {
            start(node: node, model: model, local: server)
        }
    }

    func start(node: Node, model: AppModel, local server: LocalPairing? = nil) {
        cancel()
        let server = server ?? localConsent
        local = server
        localProblem = nil
        #if DEBUG
        if let debug = DebugPairing.phase() {
            phase = debug
            backend = .software
            return
        }
        #endif
        phase = .preparing
        serverRelease = nil
        guard let keys = model.deviceKeys else {
            phase = .failed(.local("Pairing isn't available in this window."))
            return
        }
        // Pairing creates a key and writes the registry: the credential owner's job alone.
        guard model.isCredentialOwner else {
            phase = .failed(.local(CredentialOwnershipError.notOwner(operation: "pair this Mac").description))
            return
        }
        model.prepareForPairing(node.id)
        // A revoked key can never be approved again, and a paired node being re-paired starts clean too: pairing
        // again always uses a new key (docs/pairing.md §6). An unpaired node keeps the key of an earlier attempt.
        let replacing: Bool
        switch node.pairing {
        case .unpaired, .pending: replacing = false
        case .paired, .revoked: replacing = !replacedKey
        }
        replacedKey = replacedKey || replacing

        task = Task { [weak self, weak model] in
            let identity: DeviceIdentity
            do {
                identity = try await keys.identityForPairing(
                    nodeTag: node.id.rawValue, deviceName: Self.deviceName, replacingExisting: replacing)
            } catch {
                self?.phase = .failed(.local("This Mac couldn't create its key for \(node.displayName): \(error)"))
                return
            }
            guard let self, !Task.isCancelled else { return }
            backend = identity.backend
            deviceID = identity.deviceID
            if let server {
                approvingLocally = true
                await closing?.value
                do throws(LocalPairing.Failure) {
                    try await server.openWindow()
                } catch {
                    approvingLocally = false
                    phase = .failed(.local(error.description))
                    return
                }
            }
            var configuration = PairingClient.Configuration(
                endpoint: node.endpoint, deviceName: Self.deviceName, appVersion: Self.appVersion)
            // A pairing link's server key: any other is refused before anything is sent (the code still decides).
            configuration.expectedServerSPKI = model?.pairingHint(for: node.id)?.serverSPKISHA256
            let client = PairingClient(identity: identity, configuration: configuration)
            self.client = client
            for await state in client.start() {
                switch state {
                case .connecting:
                    phase = .connecting
                case .negotiated(let settled):
                    serverRelease = settled.isLegacy ? nil : settled.productLabel
                case .awaitingApproval(let code):
                    phase = .awaitingApproval(code)
                    if let server = local { await approveLocally(server, deviceID: identity.deviceID, code: code) }
                case .approved(let nodeID, let nodeName, let deviceID, let serverSPKI):
                    model?.pairingApproved(node.id, serverNodeID: nodeID, serverName: nodeName, deviceID: deviceID,
                                           serverSPKI: serverSPKI, backend: identity.backend)
                    phase = .approved(serverName: nodeName.isEmpty ? node.displayName : nodeName)
                case .denied:
                    phase = .denied
                case .expired:
                    phase = .expired
                case .failed(let failure):
                    phase = .failed(failure)
                }
                if phase.isFinished { closeLocalWindow() }
            }
        }
    }

    /// `vh device approve` for this Mac's request, after `vh` confirmed the server shows this Mac's code. A failure
    /// leaves the request waiting, so it can still be approved by hand, except a code mismatch, which denies it.
    private func approveLocally(_ server: LocalPairing, deviceID: String, code: PairingCode) async {
        approvingLocally = true
        do throws(LocalPairing.Failure) {
            try await server.approve(deviceID: deviceID, code: code.digits)
        } catch {
            localProblem = error.description
            approvingLocally = false
        }
    }

    /// Closes the pairing window this flow opened through `vh`; it would expire on its own after ten minutes.
    private func closeLocalWindow() {
        approvingLocally = false
        guard let server = local else { return }
        local = nil
        closing = Task { await server.closeWindow() }
    }

    /// Stops the attempt in progress and closes its connection.
    func cancel() {
        closeLocalWindow()
        task?.cancel()
        task = nil
        client?.cancel()
        client = nil
    }
}

#if DEBUG
/// `-VHDebugPairing awaiting|connecting|approved|denied|expired|noWindow|unreachable|changed|unexpected|incompatible` shows a
/// pairing sheet in that phase without contacting anything (for `DebugSnapshot`).
enum DebugPairing {
    static func phase() -> PairingFlow.Phase? {
        guard let name = UserDefaults.standard.string(forKey: "VHDebugPairing") else { return nil }
        switch name {
        case "connecting": return .connecting
        case "approved": return .approved(serverName: "vh-storage")
        case "denied": return .denied
        case "expired": return .expired
        case "noWindow": return .failed(.noPairingWindow)
        case "unreachable": return .failed(.unreachable(endpoint: "vh-storage.local:36972"))
        case "changed": return .failed(.serverIdentityChanged)
        case "unexpected": return .failed(.unexpectedServerIdentity)
        case "incompatible":
            return .failed(.incompatible(ProtocolMismatch(serverMin: 2, serverMax: 3, serverVersion: "2.0.0")))
        default:
            // The docs/pairing.md §8 test vector: 680 179.
            let code = try? PairingCode(
                serverSPKISHA256: Data(0..<32), deviceSPKISHA256: Data(32..<64), deviceNonce: Data(64..<96),
                serverNonce: Data(96..<128))
            return code.map(PairingFlow.Phase.awaitingApproval) ?? .connecting
        }
    }
}
#endif

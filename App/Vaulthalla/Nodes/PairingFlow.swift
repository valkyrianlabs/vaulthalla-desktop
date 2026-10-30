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

    @ObservationIgnored private var task: Task<Void, Never>?
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

    func start(node: Node, model: AppModel) {
        cancel()
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
            let client = PairingClient(identity: identity, configuration: .init(
                endpoint: node.endpoint, deviceName: Self.deviceName, appVersion: Self.appVersion))
            self.client = client
            for await state in client.start() {
                switch state {
                case .connecting:
                    phase = .connecting
                case .negotiated(let settled):
                    serverRelease = settled.isLegacy ? nil : settled.productLabel
                case .awaitingApproval(let code):
                    phase = .awaitingApproval(code)
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
            }
        }
    }

    /// Stops the attempt in progress and closes its connection.
    func cancel() {
        task?.cancel()
        task = nil
        client?.cancel()
        client = nil
    }
}

#if DEBUG
/// `-VHDebugPairing awaiting|connecting|approved|denied|expired|noWindow|unreachable|changed|incompatible` shows a
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

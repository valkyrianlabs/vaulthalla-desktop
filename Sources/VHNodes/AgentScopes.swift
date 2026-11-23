public import Foundation
public import VHCore
public import VHContract
public import VHTransport

/// What a node says an AI app's own device may do (`device.list`'s `scope`): the truth the app shows, never what it
/// asked for.
public enum AgentScopeReport: Hashable, Sendable {
    case scoped(DeviceScope)
    /// The node doesn't announce `device.scope` (an older server): it can't limit the device.
    case cannotLimit
    /// The node doesn't list the device (revoked there, or never approved).
    case notListed
    /// The node couldn't be asked now.
    case unknown(String)
}

/// Reading and changing AI apps' own devices' scopes, on this Mac's Device session only: the node refuses a scoped
/// device changing any scope (`device_scope`), and the app's own key never asks. Narrowing needs no approval; widening
/// is a `device.trust` step-up bound to the device and the new scope, which this Mac's approval key answers (one Touch
/// ID or the Mac's password). The node closes the device's live sessions on a change, so it reconnects under the new
/// scope (the bridge reconnects on its own).
public enum AgentScopes {
    public enum Change: Hashable, Sendable {
        case changed(DeviceScope)
        case unchanged
        /// Widening needs this Mac's approval key on the node.
        case needsApprovalKey
        case cannotLimit
        case failed(String)
    }

    /// The scope the node reports for each of `deviceIDs`.
    public static func report(deviceIDs: [String], via macSession: any NodeTransport) async
        -> [String: AgentScopeReport]
    {
        guard !deviceIDs.isEmpty else { return [:] }
        switch await macSession.capabilitySupport(.deviceScope) {
        case .yes: break
        case .no: return Dictionary(uniqueKeysWithValues: deviceIDs.map { ($0, .cannotLimit) })
        case .unknown:
            // A legacy node (no meta.hello) has no scopes; a session that hasn't negotiated yet can't say.
            return Dictionary(uniqueKeysWithValues: deviceIDs.map { ($0, .unknown("not connected")) })
        }
        let rows: [WsModel.Device]
        do {
            rows = try await macSession.send(Ws.Device.List.self, payload: .init()).devices
        } catch {
            return Dictionary(uniqueKeysWithValues: deviceIDs.map { ($0, .unknown(error.message)) })
        }
        var reports: [String: AgentScopeReport] = [:]
        for id in deviceIDs {
            guard let row = rows.first(where: { $0.deviceID.lowercased() == id && !$0.revoked }) else {
                reports[id] = .notListed
                continue
            }
            // A server with scopes always reports one; a value this build doesn't know reads as the widest, so the app
            // never claims a limit it can't name.
            reports[id] = .scoped(row.scope.flatMap(DeviceScope.init(rawValue:)) ?? .destructive)
        }
        return reports
    }

    /// Sets the device's scope on the node. `current` is what the node reported (decides whether it is a widening).
    public static func set(_ scope: DeviceScope, deviceID: String, current: DeviceScope?,
                           macSession: any NodeTransport, signer: (any ApprovalSigner)?,
                           context: ApprovalContext?) async -> Change {
        guard await macSession.capabilitySupport(.deviceScope) == .yes else { return .cannotLimit }
        if current == scope { return .unchanged }
        guard let wire = Ws.Device.Scope.Set.Payload.Scope(rawValue: scope.rawValue) else {
            return .failed("unknown scope \(scope.rawValue)")
        }
        do {
            let answer = try await DeviceApproval.send(Ws.Device.Scope.Set.self,
                                                       payload: .init(deviceID: deviceID, scope: wire),
                                                       signer: signer, context: context, via: macSession)
            guard answer.device.scope == scope.rawValue else {
                return .failed("the node reports \(answer.device.scope ?? "no") scope")
            }
            return .changed(scope)
        } catch let error as DeviceApprovalError {
            switch error {
            case .consoleApprovalRequired, .keyUnavailable: return .needsApprovalKey
            case .payloadMismatch: return .failed("the node's approval challenge didn't match this node")
            case .notApproved(let state): return .failed("it wasn't approved (\(state))")
            }
        } catch let error as WsError {
            if error.code == "approval_key_unavailable" { return .needsApprovalKey }
            return .failed(error.message)
        } catch {
            // The signer's own error: Touch ID cancelled or failed.
            return .failed("it wasn't approved (\(error))")
        }
    }
}

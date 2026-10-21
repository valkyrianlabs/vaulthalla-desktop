#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: the `device.*` answers for `#Preview`s and `DebugSnapshot`. "Home lab (preview)" answers
/// as a super admin, "Studio (preview)" as an account that may only see its own devices. Names say "(preview)".
nonisolated enum DevicesPreviewData: PreviewFeature {
    private struct State {
        var devices: [WsModel.Device]
        var remote = true
        var windowOpen = false
        var requests: [Ws.Device.Pairing.Pending.Response.Request] = []
    }

    private static let now = Int64(Date.now.timeIntervalSince1970)
    private static let state = Mutex(State(devices: devices))

    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        let admin = transport.scenario == .full
        let denied = WsError.denied("Only super admins may do that.")
        switch command {
        case .deviceList:
            let all = (payload as? Ws.Device.List.Payload)?.all == true
            if all && !admin { throw denied }
            let devices = state.withLock { $0.devices }
            let me = admin ? "cooper" : "studio"
            return Ws.Device.List.Response(devices: all ? devices : devices.filter { $0.userName == me })
        case .deviceRename:
            guard let rename = payload as? Ws.Device.Rename.Payload else { throw .invalid("Bad payload.") }
            let device = try update(rename.deviceID) { $0.name = rename.name }
            return Ws.Device.Rename.Response(device: device)
        case .deviceRevoke:
            guard let revoke = payload as? Ws.Device.Revoke.Payload else { throw .invalid("Bad payload.") }
            let device = try update(revoke.deviceID) {
                $0.revoked = true
                $0.revokedAt = Int64(Date.now.timeIntervalSince1970)
            }
            return Ws.Device.Revoke.Response(device: device)
        case .deviceRemoteStatus:
            guard admin else { throw denied }
            return Ws.Device.Remote.Status.Response(status: remoteStatus)
        case .deviceRemoteEnable, .deviceRemoteDisable:
            guard admin else { throw denied }
            state.withLock { $0.remote = command == .deviceRemoteEnable }
            return command == .deviceRemoteEnable
                ? Ws.Device.Remote.Enable.Response(status: .init(remoteStatus)) as Any
                : Ws.Device.Remote.Disable.Response(status: .init(remoteStatus)) as Any
        case .devicePairingOpen:
            let opened = Int64(Date.now.timeIntervalSince1970)
            state.withLock { state in
                state.windowOpen = true
                state.requests = [request(opened)]
            }
            return Ws.Device.Pairing.Open.Response(
                window: .init(ownerID: 1, openedAt: opened, expiresAt: opened + 600),
                serverTime: opened, port: 36972, remote: state.withLock { $0.remote })
        case .devicePairingPending:
            let time = Int64(Date.now.timeIntervalSince1970)
            let (open, requests) = state.withLock { ($0.windowOpen, $0.requests) }
            return Ws.Device.Pairing.Pending.Response(
                window: open ? .init(ownerID: 1, openedAt: time - 20, expiresAt: time + 580) : nil,
                requests: requests, serverTime: time)
        case .devicePairingApprove:
            guard let approve = payload as? Ws.Device.Pairing.Approve.Payload else { throw .invalid("Bad payload.") }
            guard let request = state.withLock({ $0.requests.first { $0.requestID == approve.requestID } }) else {
                throw .notFound("No such pairing request.")
            }
            state.withLock { $0.requests.removeAll { $0.requestID == approve.requestID } }
            guard approve.code == "482913" else { throw .invalid("That code doesn't match.") }
            let device = WsModel.Device(
                id: 9, deviceID: request.deviceID, userID: 1, userName: "cooper", name: request.name,
                platform: request.platform, appVersion: request.appVersion, approvedBy: 1,
                createdAt: Int64(Date.now.timeIntervalSince1970), lastIP: request.sourceIP, revoked: false)
            state.withLock { $0.devices.append(device) }
            return Ws.Device.Pairing.Approve.Response(device: device)
        case .devicePairingDeny:
            guard let deny = payload as? Ws.Device.Pairing.Deny.Payload else { throw .invalid("Bad payload.") }
            state.withLock { $0.requests.removeAll { $0.requestID == deny.requestID } }
            return Ws.Device.Pairing.Deny.Response(denied: true)
        case .devicePairingClose:
            state.withLock { state in
                state.windowOpen = false
                state.requests = []
            }
            return Ws.Device.Pairing.Close.Response(closed: true)
        default:
            return nil
        }
    }

    private static func update(_ deviceID: String, _ change: (inout WsModel.Device) -> Void) throws(WsError)
        -> WsModel.Device
    {
        let updated = state.withLock { state -> WsModel.Device? in
            guard let index = state.devices.firstIndex(where: { $0.deviceID == deviceID }) else { return nil }
            change(&state.devices[index])
            return state.devices[index]
        }
        guard let updated else { throw .notFound("No such device.") }
        return updated
    }

    private static var remoteStatus: Ws.Device.Remote.Status.Response.Status {
        let remote = state.withLock { $0.remote }
        return .init(enabled: true, remote: remote, port: 36972, listening: true,
                     address: remote ? "0.0.0.0:36972" : "127.0.0.1:36972",
                     serverSpkiSha256: "abababababababababababababababababababababababababababababababab",
                     connections: 3)
    }

    private static func request(_ time: Int64) -> Ws.Device.Pairing.Pending.Response.Request {
        .init(requestID: "preview-request", name: "Studio MacBook Pro (preview)", platform: "macOS", appVersion: "1.0.0",
              sourceIP: "10.0.0.42", deviceID: "7f3a9c1d2e4b6a80c4d1e9f0a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5",
              codeChoices: ["019337", "482913", "760001"], createdAt: time - 12, expiresAt: time + 288)
    }

    private static let devices: [WsModel.Device] = [
        device(1, "preview-device", "Cooper's MacBook Pro (preview)", user: "cooper", paired: 40, seen: 0, ip: "10.0.0.21"),
        device(2, "c5a4bd12f47b9e4a810de5de3dc0b906e20e710dfcfd344e8f934b47b6df4fe1", "Office iMac (preview)",
               user: "cooper", paired: 120, seen: 2 * 3600, ip: "10.0.0.37", version: "0.9.4"),
        device(3, "3ac2baf6c86830f39f539abce1130191e6a25b766f5ac20510f27a6b7a238fc1", "Old MacBook Air (preview)",
               user: "cooper", paired: 400, seen: 90 * 86_400, ip: "10.0.0.18", version: "0.8.0", revoked: 95),
        device(4, "preview-device-2", "Studio Mac mini (preview)", user: "studio", paired: 30, seen: 600,
               ip: "10.0.0.51"),
        device(5, "5cd252fb0ce8932436faf8ccd1040981b89ee4ad6b9fe9e2a2b7e71aacb27cd3", "Ana's MacBook Air (preview)",
               user: "ana", paired: 12, seen: nil, ip: nil),
    ]

    private static func device(_ id: Int64, _ deviceID: String, _ name: String, user: String, paired days: Int64,
                               seen: Int64?, ip: String?, version: String = "1.0.0", revoked: Int64? = nil)
        -> WsModel.Device
    {
        WsModel.Device(
            id: id, deviceID: deviceID, userID: id, userName: user, name: name, platform: "macOS", appVersion: version,
            approvedBy: 1, createdAt: now - days * 86_400, lastSeenAt: seen.map { now - $0 }, lastIP: ip,
            revokedAt: revoked.map { now - $0 * 86_400 }, revoked: revoked != nil)
    }
}

private extension Ws.Device.Remote.Enable.Response.Status {
    nonisolated init(_ status: Ws.Device.Remote.Status.Response.Status) {
        self.init(enabled: status.enabled, remote: status.remote, port: status.port, listening: status.listening,
                  address: status.address, error: status.error, serverSpkiSha256: status.serverSpkiSha256,
                  connections: status.connections)
    }
}

private extension Ws.Device.Remote.Disable.Response.Status {
    nonisolated init(_ status: Ws.Device.Remote.Status.Response.Status) {
        self.init(enabled: status.enabled, remote: status.remote, port: status.port, listening: status.listening,
                  address: status.address, error: status.error, serverSpkiSha256: status.serverSpkiSha256,
                  connections: status.connections)
    }
}
#endif

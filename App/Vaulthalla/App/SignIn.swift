import AppKit
import Foundation
import os
import VHContract
import VHCore
import VHFinder
import VHNodes
import VHTransport

/// Staying signed in (desktop#7). Pairing is the sign-in: a node approves this Mac once, and its Secure Enclave key
/// (Keychain, `AfterFirstUnlockThisDeviceOnly`) and the registry carry it across quits, restarts and reboots. Both live
/// in this macOS account (its data protection keychain and its App Group container), so every account on the Mac has
/// its own nodes and keys and never sees another's. Which Vaulthalla user a device acts as is whoever approved it on
/// the node; nothing on the Mac (account name, uid) is ever taken as proof of that.
///
/// "Keep me signed in on this Mac" (on by default) is the only switch. Off, quitting Vaulthalla or logging out of
/// macOS signs out (``SignOut``): this Mac is revoked on every node it can reach, its keys are deleted, the nodes return
/// to unpaired and Finder's vaults are removed. A launch that finds paired nodes with the switch off means the last
/// sign-out never ran (force quit, crash, power loss), so it signs out then, before anything else.
enum SignInPreferences {
    static let keepSignedInKey = "signIn.keepSignedIn"

    static var keepSignedIn: Bool {
        get { UserDefaults.standard.object(forKey: keepSignedInKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepSignedInKey) }
    }
}

extension AppModel {
    /// Whether signing out has anything to do: a node is paired, or keeps a key from a pairing attempt.
    var hasSignedInNodes: Bool {
        nodes.contains { $0.pairing != .unpaired }
    }

    /// Signs this Mac out of every node and takes its vaults out of Finder (``SignOut``). Only the credential owner
    /// may: it holds the keys. Returns nil when this app isn't the owner.
    @discardableResult
    func signOut() async -> SignOut.Report? {
        guard isCredentialOwner, let keys = deviceKeys else { return nil }
        let log = Logger(subsystem: "sh.vaulthalla.app", category: "sign-in")
        let report = await SignOut.run(nodes) { [weak self] target in
            try await self?.revokeThisMac(target)
        } removeDomains: {
            try await FileProviderDomains().removeAll()
            // Finder selections still waiting behind the consent gate (FinderVaults' `finder.pendingDomains`).
            UserDefaults.standard.removeObject(forKey: "finder.pendingDomains")
        } forget: { [weak self] id in
            self?.prepareForPairing(id)
            try? await keys.deleteIdentity(for: id.rawValue)
            self?.updatePairing(.unpaired, for: id)
        }
        log.notice("signed out: \(report.revoked.count) revoked, \(report.notRevoked.count) not reached")
        return report
    }

    /// At launch, with "Keep me signed in" off: paired nodes mean the last sign-out didn't run, so it runs now.
    func signOutIfNotKept() {
        guard !SignInPreferences.keepSignedIn, isCredentialOwner, hasSignedInNodes else { return }
        Task { await signOut() }
    }

    /// `device.revoke` for this Mac, once the node's session is online (it may still be connecting at launch);
    /// ``SignOut`` bounds the wait.
    private func revokeThisMac(_ target: SignOut.Target) async throws {
        while true {
            guard let node = node(withID: target.node) else { return }
            if status(for: node) == .online, let queries = queries(for: target.node) {
                switch await queries.perform(Ws.Device.Revoke.self, .init(deviceID: target.deviceID)) {
                case .success: return
                case .failure(let error): throw error
                case .needsConfirmation(let request): throw WsError.error(request.message)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Signs out on quit and at logout (macOS quits every app then) while "Keep me signed in" is off.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var signingOut = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !SignInPreferences.keepSignedIn, let model, model.isCredentialOwner, model.hasSignedInNodes else {
            return .terminateNow
        }
        if !signingOut {
            signingOut = true
            Task {
                await model.signOut()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

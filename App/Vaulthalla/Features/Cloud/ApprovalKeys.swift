import AppKit
import CryptoKit
import Foundation
import VHCloud
import VHCore
import VHNodes

/// This Mac's approval keys, one per node (server #361): Secure Enclave P-256 signing keys whose data representations
/// live in the account's app-only keychain items (`approval-key.<node id>`), written only by the credential owner.
@MainActor
final class ApprovalKeys {
    private let items: LeasedAccountItems
    private var registered: Set<NodeID> = []

    init(items: LeasedAccountItems) { self.items = items }

    private func name(_ id: NodeID) -> String { "approval-key.\(id.rawValue)" }

    /// The node's approval key; `create` makes one when there is none.
    func signer(for id: NodeID, create: Bool = false) throws -> any ApprovalSigner {
        if let stored = try items.items.read(name(id)) {
            return try EnclaveApprovalKey(storedRepresentation: stored)
        }
        guard create else { throw DeviceApprovalError.keyUnavailable }
        guard items.role == .owner else { throw CredentialOwnershipError.notOwner(operation: "make an approval key") }
        let key = try EnclaveApprovalKey.create(userPresence: AccountKeychain.accessGroup() != nil)
        try items.items.write(name(id), key.storedRepresentation)
        return key
    }

    func hasKey(_ id: NodeID) -> Bool { ((try? items.items.read(name(id))) ?? nil) != nil }
    func markRegistered(_ id: NodeID) { registered.insert(id) }
    func isRegistered(_ id: NodeID) -> Bool { registered.contains(id) }

    func forgetAll() {
        registered = []
    }

    /// What this Mac knows about a paired node that the approval payload must name.
    static func context(for node: Node) -> ApprovalContext? {
        guard case .paired(let pin, let deviceID, _) = node.pairing, let nodeID = node.serverNodeID,
              let device = hex(deviceID), device.count == 32 else { return nil }
        return ApprovalContext(nodeID: nodeID, serverSPKISHA256: pin, deviceSPKISHA256: device)
    }

    private static func hex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var out = Data()
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            guard let b = UInt8(text[i ..< j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}

/// Prints the recovery code on one page with its fingerprint and what it is for.
enum RecoveryCodePrinter {
    static func print(code: String, fingerprint: String) {
        let text = NSMutableAttributedString()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18)]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold)]
        text.append(NSAttributedString(string: "Vaulthalla Cloud recovery key\n\n", attributes: title))
        text.append(NSAttributedString(string: "\(code)\n\n", attributes: mono))
        text.append(NSAttributedString(string: "Fingerprint: \(fingerprint)\n\n", attributes: body))
        text.append(NSAttributedString(string: "With this recovery key, your files can be recovered even if you lose every device and Vaulthalla Cloud is unavailable. Nobody else has a copy. Keep it like a house key: whoever has it and reaches your storage can open your vaults.\n", attributes: body))
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        view.textStorage?.setAttributedString(text)
        let operation = NSPrintOperation(view: view)
        operation.jobTitle = "Vaulthalla recovery key"
        operation.run()
    }
}

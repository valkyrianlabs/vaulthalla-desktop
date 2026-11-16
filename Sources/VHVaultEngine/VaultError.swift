import Foundation
import VLVaultfmt

/// A status of vl-vaultfmt's C API (vl_vaultfmt.h, vl_vaultfmt_engine.h): stable numbers with stable names.
public enum VaultStatus {
    public static let ok: Int32 = 0
    public static let invalidArgument: Int32 = 1
    public static let bufferTooSmall: Int32 = 2
    public static let notFound: Int32 = 6
    public static let storeFailed: Int32 = 600
    public static let storePreconditionFailed: Int32 = 601
    public static let storeConditionsUnsupported: Int32 = 602
    public static let storeOutcomeUnknown: Int32 = 603
    public static let stateFailed: Int32 = 604
    public static let stateTooNew: Int32 = 605
    public static let stateOtherVault: Int32 = 606
    public static let publishConflict: Int32 = 607
    public static let publishUnsettled: Int32 = 608
    public static let publishUnsupported: Int32 = 609
    public static let noUsableRoot: Int32 = 610
    public static let writerFloor: Int32 = 611
    public static let applyStopped: Int32 = 612
    public static let notADirectory: Int32 = 621
    public static let nameExists: Int32 = 622
    public static let invalidName: Int32 = 623
    public static let invalidMove: Int32 = 624
    public static let keyNotAdded: Int32 = 625
    public static let recipientRequired: Int32 = 626
    public static let keyMismatch: Int32 = 627
    public static let keyVersion: Int32 = 628
    public static let badEnvelope: Int32 = 629
    public static let noVault: Int32 = 630
    public static let busy: Int32 = 631

    /// The library's stable name for `status` ("ok", "store_failed", "vhf1_chunk_auth_failed").
    public static func name(_ status: Int32) -> String { String(cString: vl_vaultfmt_status_name(status)) }
}

/// A failed engine call: the library's status, its stable name, and the library's message (which never carries a key
/// or a secret; Desktop adds none). `message` may name entries by uid.
public struct VaultError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: Int32
    public let name: String
    public let message: String

    public init(status: Int32, message: String = "") {
        self.status = status
        name = VaultStatus.name(status)
        self.message = message
    }

    /// An error Desktop raises itself (no library call failed): a name of its own.
    package init(local name: String, _ message: String) {
        status = -1
        self.name = name
        self.message = message
    }

    public var description: String { message.isEmpty ? "VaultError(\(name))" : "VaultError(\(name): \(message))" }

    public var isNotFound: Bool { status == VaultStatus.notFound }
    /// A failure of the network or the bucket: trying again later may work.
    public var isTransient: Bool {
        [VaultStatus.storeFailed, VaultStatus.storeOutcomeUnknown, VaultStatus.publishConflict,
         VaultStatus.publishUnsettled].contains(status)
    }

    /// What a person reads.
    public var sentence: String {
        switch status {
        case VaultStatus.notFound: "It isn't in the vault any more."
        case VaultStatus.nameExists: "Something with that name is already there."
        case VaultStatus.invalidName: "That name can't be used in a vault (1 to 255 bytes, no \u{201C}/\u{201D})."
        case VaultStatus.invalidMove: "It can't be moved there."
        case VaultStatus.notADirectory: "That isn't a folder."
        case VaultStatus.busy: "The file changed while it was being written. Nothing was saved; try again."
        case VaultStatus.storeFailed, VaultStatus.storeOutcomeUnknown:
            "The vault's storage can't be reached right now. Changes stay on this Mac and are sent later."
        case VaultStatus.stateFailed: "This Mac couldn't save the vault's state. Nothing changed."
        case VaultStatus.stateTooNew: "A newer version of Vaulthalla wrote this vault's state on this Mac. Update Vaulthalla."
        case VaultStatus.stateOtherVault: "The vault's state on this Mac belongs to another vault or Mac."
        case VaultStatus.writerFloor:
            "A newer version of Vaulthalla wrote this vault. This Mac reads it but sends nothing until Vaulthalla is updated."
        case VaultStatus.noUsableRoot: "None of this Mac's keys opens the vault's storage."
        case VaultStatus.applyStopped: "This Mac stopped taking in the vault's storage: \(message)"
        case VaultStatus.publishConflict, VaultStatus.publishUnsettled:
            "The vault's storage is settling. This Mac sends its changes again shortly."
        case VaultStatus.keyNotAdded, VaultStatus.keyMismatch, VaultStatus.keyVersion, VaultStatus.recipientRequired,
             VaultStatus.badEnvelope:
            "The vault's key on this Mac isn't the one its storage expects."
        case VaultStatus.noVault: "There is no vault in this storage yet."
        default: message.isEmpty ? "The vault refused this (\(name))." : message
        }
    }
}

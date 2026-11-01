public import VHCore

/// Which vault a File Provider domain shows: one domain per vault the operator selects (valkyrianlabs/vaulthalla-desktop#1), on a
/// node of this Mac's registry.
///
/// Its identifier is `<node id>.<vault id>`, which survives renames of the node and the vault and contains neither `/`
/// nor `:` (the File Provider uses domain identifiers in paths). Node ids are therefore limited to ASCII letters,
/// digits, `-` and `_`, which every id Desktop makes (`local-<uuid>`) satisfies; vault ids are the daemon's
/// non-negative integers.
public struct VaultDomainID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let nodeID: NodeID
    public let vaultID: Int64

    /// nil when `nodeID` has a character an identifier can't carry, or `vaultID` is negative.
    public init?(nodeID: NodeID, vaultID: Int64) {
        guard Self.isUsable(nodeID: nodeID.rawValue), vaultID >= 0 else { return nil }
        self.nodeID = nodeID
        self.vaultID = vaultID
    }

    /// Parses `<node id>.<vault id>` as ``identifier`` writes it; nil for anything else.
    public init?(identifier: String) {
        guard let dot = identifier.lastIndex(of: ".") else { return nil }
        let digits = identifier[identifier.index(after: dot)...]
        guard let vaultID = Int64(digits), String(vaultID) == digits else { return nil }
        self.init(nodeID: NodeID(rawValue: String(identifier[..<dot])), vaultID: vaultID)
    }

    /// The domain's identifier, `<node id>.<vault id>`.
    public var identifier: String { "\(nodeID.rawValue).\(vaultID)" }

    public var description: String { identifier }

    private static func isUsable(nodeID: String) -> Bool {
        !nodeID.isEmpty && nodeID.count <= 128
            && nodeID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// A domain as Desktop wants it to exist: which vault, and what Finder calls it.
public struct VaultDomain: Hashable, Sendable, Identifiable, Codable {
    public let id: VaultDomainID
    public let displayName: String

    public init(id: VaultDomainID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// The domain of `vaultID` on `node`, named `<vault> · <node>`; nil when the node's id can't name a domain.
    public init?(node: Node, vaultID: Int64, vaultName: String) {
        guard let id = VaultDomainID(nodeID: node.id, vaultID: vaultID) else { return nil }
        self.init(id: id, displayName: Self.displayName(vault: vaultName, node: node.displayName, vaultID: vaultID))
    }

    /// `<vault> · <node label>`, the name Finder shows in its sidebar and in the domain's folder name (the system
    /// drops some characters there, spaces among them). Line breaks and runs of whitespace become one space, `/` and
    /// `:` become `-`; an empty vault name falls back to `Vault <id>`, an empty node label leaves just the vault.
    public static func displayName(vault: String, node: String, vaultID: Int64) -> String {
        let vaultPart = clean(vault)
        let nodePart = clean(node)
        let name = vaultPart.isEmpty ? "Vault \(vaultID)" : vaultPart
        return nodePart.isEmpty ? name : "\(name) · \(nodePart)"
    }

    private static func clean(_ text: String) -> String {
        let replaced = String(text.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        return replaced.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

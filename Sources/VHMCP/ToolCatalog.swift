import VHContract
import VHCore

/// The aggregated `tools/list`: every paired, reachable node's tools, each with a required `node` argument.
///
/// **Deduplication.** Nodes run the same catalog, so a tool is listed once per name with the nodes that offer it.
/// Nodes on different Vaulthalla versions can disagree about a tool (its schema, description or annotations). The
/// definitions of a name are then grouped into variants: the variant offered by the most nodes (ties: the node
/// first in the operator's order) keeps the plain name, and each other variant is listed as `<name>_v2`, `_v3`, ...
/// with its own definition and annotations, unchanged, and a note naming its nodes. A call reaches only the nodes
/// that offer that exact variant, so a client never sees one node's read-only hint on another node's destructive
/// tool, and nothing is merged or rewritten except the added `node` argument.
///
/// **Never listed.** A tool named `nodes_list` (the bridge's own), a tool that already declares a `node` argument
/// (it couldn't be routed unambiguously), and, defensively, any tool whose name speaks of exporting or importing keys
/// or exporting secrets: the daemon never offers those over MCP (D4), and the bridge wouldn't pass them on if one did.
struct ToolCatalog: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// The name the client calls.
        var name: String
        /// The name on the nodes.
        var remoteName: String
        /// The nodes offering this exact definition, in registry order.
        var nodes: [NodeID]
        /// The definition the client sees (with `node`).
        var definition: JSONValue
    }

    static let nodesListName = "nodes_list"
    /// The argument that picks the node.
    static let nodeArgument = "node"

    private(set) var entries: [Entry] = []
    private var index: [String: Int] = [:]

    subscript(name: String) -> Entry? { index[name].map { entries[$0] } }

    /// The remote tools for `tools/list` (the bridge puts its own first).
    var definitions: [JSONValue] { entries.map(\.definition) }

    /// Every variant of the remote tool `remoteName`, for telling the client which one a node offers.
    func variants(of remoteName: String) -> [Entry] { entries.filter { $0.remoteName == remoteName } }

    init() {}

    /// `nodes`: each reachable node with the tools it listed, in the operator's order.
    init(nodes: [(node: Node, tools: [JSONValue])]) {
        struct Variant {
            var definition: JSONValue
            var nodes: [Node]
            var firstPosition: Int
        }
        var order: [String] = []
        var variants: [String: [Variant]] = [:]
        for (position, item) in nodes.enumerated() {
            var seen: Set<String> = []
            for tool in item.tools {
                guard let name = tool["name"]?.stringValue, !name.isEmpty, Self.isListable(tool),
                      seen.insert(name).inserted
                else { continue }
                if variants[name] == nil { order.append(name) }
                var list = variants[name] ?? []
                if let match = list.firstIndex(where: { $0.definition == tool }) {
                    list[match].nodes.append(item.node)
                } else {
                    list.append(Variant(definition: tool, nodes: [item.node], firstPosition: position))
                }
                variants[name] = list
            }
        }

        let taken = Set(order)
        var used: Set<String> = [Self.nodesListName]
        for name in order {
            let ranked = (variants[name] ?? []).sorted {
                $0.nodes.count != $1.nodes.count ? $0.nodes.count > $1.nodes.count : $0.firstPosition < $1.firstPosition
            }
            var exposedNames: [String] = []
            for rank in ranked.indices {
                var exposed = name
                if rank > 0 {
                    var suffix = rank + 1
                    exposed = "\(name)_v\(suffix)"
                    while taken.contains(exposed) || used.contains(exposed) {
                        suffix += 1
                        exposed = "\(name)_v\(suffix)"
                    }
                }
                used.insert(exposed)
                exposedNames.append(exposed)
            }
            for (rank, variant) in ranked.enumerated() {
                let others = ranked.indices.filter { $0 != rank }.map { exposedNames[$0] }
                let definition = Self.expose(variant.definition, as: exposedNames[rank], nodes: variant.nodes,
                                             otherVariants: rank == 0 ? others : [],
                                             primary: rank == 0 ? nil : exposedNames[0])
                index[exposedNames[rank]] = entries.count
                entries.append(Entry(name: exposedNames[rank], remoteName: name, nodes: variant.nodes.map(\.id),
                                     definition: definition))
            }
        }
    }

    // MARK: - Filtering

    static func isListable(_ tool: JSONValue) -> Bool {
        guard let name = tool["name"]?.stringValue else { return false }
        if name == nodesListName || isKeyMaterial(toolName: name) { return false }
        if tool["inputSchema"]?["properties"]?[nodeArgument] != nil { return false }
        return true
    }

    /// Names that speak of moving key material: `vault_keys_export`, `keys_import`, `secrets_export`, ...
    static func isKeyMaterial(toolName: String) -> Bool {
        let words = Set(toolName.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let keys = !words.isDisjoint(with: ["key", "keys", "secret", "secrets"])
        let moves = !words.isDisjoint(with: ["export", "import", "reveal"])
        return keys && moves || words.contains("secrets") && words.contains("update")
    }

    /// A command line (`vh_run`'s `command`) that would export or import key material: refused by the bridge too.
    static func isKeyMaterial(commandLine: String) -> Bool {
        let words = commandLine.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
            .map(String.init)
        guard let verb = words.firstIndex(where: { ["export", "import", "reveal"].contains($0) }) else {
            return words.contains("secrets") && words.contains("update")
        }
        return words[..<verb].contains { ["key", "keys", "secret", "secrets"].contains($0) }
    }

    // MARK: - Shaping

    /// The definition with `node` added (required, first) and the notes about where the tool is offered.
    private static func expose(_ tool: JSONValue, as name: String, nodes: [Node], otherVariants: [String],
                               primary: String?) -> JSONValue
    {
        guard case .object(var object) = tool else { return tool }
        object["name"] = .string(name)

        let offeredBy = nodes.map { "\($0.displayName) (\($0.id.rawValue))" }.joined(separator: ", ")
        var schema = object["inputSchema"]?.objectValue ?? ["type": "object"]
        var properties = schema["properties"]?.objectValue ?? [:]
        properties[nodeArgument] = [
            "type": "string",
            "minLength": 1,
            "description": .string("The Vaulthalla node to run this on: its id or name (see nodes_list). "
                + "Offered by: \(offeredBy)."),
        ]
        schema["properties"] = .object(properties)
        let required = (schema["required"]?.arrayValue ?? []).filter { $0 != .string(nodeArgument) }
        schema["required"] = .array([.string(nodeArgument)] + required)
        object["inputSchema"] = .object(schema)

        var notes: [String] = []
        if let primary {
            notes.append("This is \(primary) as the nodes \(nodes.map(\.displayName).joined(separator: ", ")) "
                + "define it (another Vaulthalla version); use it only with those nodes.")
        }
        if !otherVariants.isEmpty {
            notes.append("Some nodes run another Vaulthalla version and define this tool differently: for those, "
                + "use \(otherVariants.joined(separator: ", ")).")
        }
        if !notes.isEmpty {
            let description = object["description"]?.stringValue ?? ""
            object["description"] = .string((notes + [description]).filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        return .object(object)
    }
}

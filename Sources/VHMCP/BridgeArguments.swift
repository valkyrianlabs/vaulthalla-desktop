public import VHCore

/// The bridge's command line. `--client <name>` (or `--client=<name>`) names the AI app it serves, as the app's
/// registrations pass it; without it the bridge serves every paired node as it always did. Anything else is refused,
/// so a typo can't silently widen what an app reaches.
public enum BridgeArguments {
    public static func parse(_ arguments: some Sequence<String>) -> Result<AgentClient?, Refusal> {
        var client: AgentClient?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            let value: String
            if argument == "--client" {
                guard let next = iterator.next() else { return .failure(Refusal("--client needs a value")) }
                value = next
            } else if argument.hasPrefix("--client=") {
                value = String(argument.dropFirst("--client=".count))
            } else {
                return .failure(Refusal("unknown argument \(argument)"))
            }
            guard client == nil else { return .failure(Refusal("--client given twice")) }
            guard let known = AgentClient(rawValue: value) else {
                return .failure(Refusal("unknown --client \(value)"))
            }
            client = known
        }
        return .success(client)
    }

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let reason: String
        init(_ reason: String) { self.reason = reason }

        public var description: String {
            "vaulthalla-mcp: \(reason). Usage: vaulthalla-mcp [--client "
                + AgentClient.allCases.map(\.rawValue).joined(separator: "|") + "]"
        }
    }
}

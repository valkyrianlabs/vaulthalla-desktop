public import VHContract
public import VHCore
public import VHNodes
public import VHTransport

/// Recovery Keys' change detection: `vault.keys.status` on every connected node at once.
public enum KeyStatusPoll {
    /// One node's answer.
    public typealias Outcome = Result<[WsModel.VaultKeyStatus], WsError>

    /// Asks every node for its key status at once and hands each node's answer to `answered` as it arrives. Returns
    /// once every node has answered or failed.
    @MainActor
    public static func run(_ nodes: [KeyBackupNode], answered: (NodeID, Outcome) -> Void) async {
        await withTaskGroup(of: (NodeID, Outcome).self) { group in
            for node in nodes {
                let transport = node.transport
                let id = node.id
                // The answer is settled before the tuple is built around it. Swift 6.4's optimizer miscompiles
                // `do { return (id, .success(try await …)) } catch { return (id, .failure(error)) }` here: it stores
                // `id` only on the catch path, so every successful answer arrived with an uninitialized NodeID and
                // Desktop 0.6.0 crashed at launch (KeyStatusPollTests).
                group.addTask {
                    let outcome = await outcome(of: transport)
                    return (id, outcome)
                }
            }
            for await (id, outcome) in group { answered(id, outcome) }
        }
    }

    private static func outcome(of transport: any NodeTransport) async -> Outcome {
        do throws(WsError) {
            return .success(try await VaultKeyCommands(transport).status())
        } catch {
            return .failure(error)
        }
    }
}

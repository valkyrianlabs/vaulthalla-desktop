// THROWAWAY SPIKE (vaulthalla/desktop#2). A separate agent process (Contents/Library/LoginItems/SpikeAgent.app):
// can a process other than the app reach the domains and signal the working set?
import FileProvider
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
Task {
    do {
        Spike.log("agent bundle \(Bundle.main.bundleIdentifier ?? "?") args \(args)")
        let (status, value, group) = Spike.readSecret()
        Spike.log("agent secret read: \(Spike.describe(status)) value=\(value ?? "nil") group=\(group ?? "nil")")
        if !(try await Domains.run(args.isEmpty ? ["list-domains"] : args)) {
            Spike.log("unknown command \(args)")
        }
        exit(0)
    } catch {
        Spike.log("agent FAILED \(args): \(error)")
        exit(1)
    }
}
dispatchMain()

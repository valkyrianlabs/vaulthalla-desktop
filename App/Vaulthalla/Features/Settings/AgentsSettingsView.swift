import AppKit
import SwiftUI
import VHAgents
import VHCore

/// The bundled `vaulthalla-mcp` bridge and the commands that register it by hand (Settings → Agents, "Manual setup").
/// The app registers it itself through ``AgentAppsModel`` (docs/architecture.md §5, "Registration").
enum AgentBridge {
    /// The name the clients list the server under.
    static let serverName = agentServerName

    /// `Vaulthalla.app/Contents/Helpers/vaulthalla-mcp`.
    static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/vaulthalla-mcp", directoryHint: .notDirectory)
    }

    static func claudeCommand(_ path: String) -> String {
        "claude mcp add --scope user \(serverName) -- \(shellQuoted(path)) --client \(AgentClient.claudeCode.rawValue)"
    }

    static func codexCommand(_ path: String) -> String {
        "codex mcp add \(serverName) -- \(shellQuoted(path)) --client \(AgentClient.codex.rawValue)"
    }

    /// For `~/.codex/config.toml` by hand. Codex gives a tool 60 s by default; the bridge allows a call 10 minutes.
    static func codexTOML(_ path: String) -> String {
        """
        [mcp_servers.\(serverName)]
        command = \(tomlQuoted(path))
        args = ["--client", "\(AgentClient.codex.rawValue)"]
        tool_timeout_sec = \(CodexIntegration.toolTimeout)
        """
    }

    /// Double quotes, with the characters the shell still expands inside them escaped.
    static func shellQuoted(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\"\\$`".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    static func tomlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Each AI app's state, and adding or removing the bridge, through VHAgents. Every check runs off the main actor in
/// the library (external processes with deadlines); this only holds what the view shows.
@MainActor @Observable final class AgentAppsModel {
    private(set) var statuses: [AgentClient: AgentAppStatus] = [:]
    private(set) var working: Set<AgentClient> = []
    /// The last outcome worth showing, per app (a failure, a note, or Claude's install sheet being open).
    private(set) var messages: [AgentClient: Message] = [:]
    private var environment: AgentEnvironment?

    struct Message: Equatable {
        var text: String
        var tone: StatusTone
    }

    private func integration(for client: AgentClient) async -> any AgentAppIntegration {
        let environment: AgentEnvironment
        if let cached = self.environment {
            environment = cached
        } else {
            environment = await AgentEnvironment.current()
            self.environment = environment
        }
        switch client {
        case .claudeCode:
            return ClaudeCodeIntegration(environment: environment)
        case .claudeDesktop:
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            return ClaudeDesktopIntegration(environment: environment, version: version, iconPNG: Self.iconPNG())
        case .codex:
            return CodexIntegration(environment: environment)
        }
    }

    func refreshAll(bridge: URL) async {
        // The login shell's PATH is asked once, before the three checks share it.
        if environment == nil { environment = await AgentEnvironment.current() }
        await withTaskGroup(of: Void.self) { group in
            for client in AgentClient.allCases {
                group.addTask { await self.refresh(client, bridge: bridge) }
            }
        }
    }

    func refresh(_ client: AgentClient, bridge: URL) async {
        working.insert(client)
        defer { working.remove(client) }
        let integration = await integration(for: client)
        statuses[client] = await integration.status(bridge: bridge)
    }

    func add(_ client: AgentClient, bridge: URL) async {
        working.insert(client)
        messages[client] = nil
        let integration = await integration(for: client)
        let outcome = await integration.add(bridge: bridge)
        working.remove(client)
        await show(outcome, for: client)
        await refresh(client, bridge: bridge)
    }

    func remove(_ client: AgentClient, bridge: URL) async {
        working.insert(client)
        messages[client] = nil
        let integration = await integration(for: client)
        let outcome = await integration.remove(bridge: bridge)
        working.remove(client)
        await show(outcome, for: client)
        await refresh(client, bridge: bridge)
    }

    private func show(_ outcome: AgentActionOutcome, for client: AgentClient) async {
        switch outcome {
        case .done:
            messages[client] = nil
        case .doneWithNote(let note):
            messages[client] = Message(text: note, tone: .warn)
        case .manual(let text):
            messages[client] = Message(text: text, tone: .info)
        case .failed(let text):
            messages[client] = Message(text: text, tone: .danger)
        case .openBundle(let bundle, let application):
            do {
                _ = try await NSWorkspace.shared.open([bundle], withApplicationAt: application,
                                                      configuration: NSWorkspace.OpenConfiguration())
                messages[client] = Message(
                    text: "Claude is showing its install window. Click Install there, then Check Again here.",
                    tone: .info)
            } catch {
                messages[client] = Message(text: "Claude couldn't open the bundle: \(error.localizedDescription)",
                                           tone: .danger)
            }
        }
    }

    /// The app icon for Claude's install sheet.
    private static func iconPNG() -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let size = NSSize(width: 256, height: 256)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

struct AgentsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apps = AgentAppsModel()
    @State private var access = AgentAccess()
    @State private var accessProblem: String?

    private let helper = AgentBridge.helperURL
    private var path: String { helper.path(percentEncoded: false) }
    private var location: BridgeLocation { BridgeLocation.check(helper) }
    private var accessURL: URL { AgentAccess.fileURL(besideRegistry: model.registryURL) }
    private var pairedNodes: [Node] {
        model.nodes.filter { if case .paired = $0.pairing { true } else { false } }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Bridge") {
                    Text(path)
                        .font(.callout.monospaced())
                        .foregroundStyle(.fgMuted)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                switch location {
                case .missing:
                    Label("This build doesn't contain the bridge.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StatusTone.warn.color)
                case .unstable(let why):
                    Label(why, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StatusTone.warn.color)
                case .stable(inApplications: false):
                    Text("Move Vaulthalla to Applications before adding it, so the path stays valid.")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                case .stable(inApplications: true):
                    EmptyView()
                }
            } header: {
                Text("MCP bridge")
            } footer: {
                Text("AI apps start the bridge themselves. It reaches the nodes this Mac is paired with, through the "
                    + "same pairing the app uses; Vaulthalla doesn't need to be open.")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }

            Section("AI apps") {
                ForEach(AgentClient.allCases) { client in
                    AgentAppRow(client: client, status: apps.statuses[client], working: apps.working.contains(client),
                                message: apps.messages[client], canAdd: location.allowsAdding,
                                add: { Task { await apps.add(client, bridge: helper) } },
                                remove: { Task { await apps.remove(client, bridge: helper) } },
                                check: { Task { await apps.refresh(client, bridge: helper) } })
                }
            }

            Section {
                if let accessProblem {
                    Label(accessProblem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StatusTone.warn.color)
                }
                if pairedNodes.isEmpty {
                    Text("No paired nodes yet.")
                        .foregroundStyle(.fgSubtle)
                }
                ForEach(pairedNodes) { node in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(node.displayName)
                            .fontWeight(.medium)
                        HStack(spacing: 16) {
                            ForEach(AgentClient.allCases) { client in
                                Toggle(client.displayName, isOn: binding(node.id, client))
                                    .toggleStyle(.checkbox)
                                    .disabled(accessProblem != nil)
                            }
                        }
                        .font(.callout)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(node.displayName): available to")
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Available to")
            } footer: {
                Text("Every paired node, including ones you pair later, is available to every AI app until you turn "
                    + "it off here. A node turned off for an app is hidden from it and its calls are refused. This "
                    + "applies to apps added here; a registration made by hand without --client reaches every node.")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }

            Section {
                Callout(tone: .info, systemImage: "lock.shield") {
                    Text("AI apps act as you on each node")
                        .fontWeight(.semibold)
                        .foregroundStyle(.fg)
                    Text("On every node it can use, an AI app acts as the Vaulthalla account this Mac was paired by, "
                        + "with that account's permissions. Destructive commands wait for your approval in the app, "
                        + "and AI apps can never export or import vault keys.")
                        .foregroundStyle(.fgMuted)
                }
            }

            Section {
                DisclosureGroup("Manual setup") {
                    VStack(alignment: .leading, spacing: 12) {
                        CopyableCommand(command: AgentBridge.claudeCommand(path), caption: "Claude Code:")
                        CopyableCommand(command: AgentBridge.codexCommand(path), caption: "Codex:")
                        CopyableCommand(command: AgentBridge.codexTOML(path), caption: "Or add to ~/.codex/config.toml:")
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .task {
            loadAccess()
            await apps.refreshAll(bridge: helper)
        }
    }

    private func loadAccess() {
        do {
            access = try AgentAccess.load(from: accessURL)
            accessProblem = nil
        } catch {
            accessProblem = "\(error.description). Until it's fixed, AI apps added here can't use any node."
        }
    }

    private func binding(_ node: NodeID, _ client: AgentClient) -> Binding<Bool> {
        Binding(
            get: { access.isAvailable(node, to: client) },
            set: { available in
                var changed = access
                changed.set(node, available: available, to: client)
                changed.prune(keeping: model.nodes.map(\.id))
                do {
                    try changed.save(to: accessURL)
                    access = changed
                } catch {
                    accessProblem = "The switch couldn't be saved: \(error.localizedDescription)"
                }
            })
    }
}

/// One AI app: what Vaulthalla found, and the one action that fits.
private struct AgentAppRow: View {
    var client: AgentClient
    var status: AgentAppStatus?
    var working: Bool
    var message: AgentAppsModel.Message?
    var canAdd: Bool
    var add: () -> Void
    var remove: () -> Void
    var check: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.displayName)
                        .fontWeight(.medium)
                    Text(summary.text)
                        .font(.callout)
                        .foregroundStyle(summary.tone.color)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    actions
                }
            }
            if let message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.tone.color)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var actions: some View {
        switch status?.registration {
        case .notAdded?, .otherScope?:
            Button("Add", action: add).disabled(!canAdd)
        case .stale?, .handMade?:
            Button("Repair", action: add).disabled(!canAdd)
            Button("Remove", role: .destructive, action: remove)
        case .current?:
            if client == .codex, case .installed(_, let report) = status,
               report.toolTimeout != Double(CodexIntegration.toolTimeout) {
                Button("Repair", action: add).disabled(!canAdd)
            }
            Button("Remove", role: .destructive, action: remove)
        case .unknown?:
            Button("Add", action: add).disabled(!canAdd)
            Button("Check Again", action: check)
        case nil:
            if status != nil { Button("Check Again", action: check) }
        }
        if client == .claudeDesktop, status?.registration == .notAdded { Button("Check Again", action: check) }
    }

    private var summary: (text: String, tone: StatusTone) {
        guard let status else { return ("Checking…", .unknown) }
        switch status {
        case .notInstalled:
            return ("Not found on this Mac", .unknown)
        case .unsupported(_, let detail):
            return (detail, .warn)
        case .failed(_, let detail):
            return ("Couldn't check: \(detail)", .danger)
        case .installed(_, let report):
            switch report.registration {
            case .notAdded:
                return ("Not added", .unknown)
            case .current:
                if let health = report.health, health != "Connected" { return ("Added; it reports: \(health)", .warn) }
                if client == .codex, report.toolTimeout != Double(CodexIntegration.toolTimeout) {
                    return ("Added; calls stop after Codex's default 60 seconds", .warn)
                }
                return ("Added", .ok)
            case .handMade:
                return ("Added by hand: the switches below don't apply until it's repaired", .warn)
            case .stale(let registered):
                return ("Added for another copy of Vaulthalla (\(registered))", .warn)
            case .otherScope(let scope):
                return ("Only in Claude Code's \(scope)", .warn)
            case .unknown:
                return ("Vaulthalla can't tell whether Claude has it", .unknown)
            }
        }
    }

    private var detail: String? {
        let found: FoundApp? = switch status {
        case .unsupported(let found, _)?, .failed(let found, _)?, .installed(let found, _)?: found
        default: nil
        }
        guard let found else {
            return client == .claudeCode || client == .codex
                ? "Looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin and your login shell's PATH." : nil
        }
        let scope = switch client {
        case .claudeCode: " · also the Code tab in Claude"
        case .codex: " · also Codex in ChatGPT and the IDE extension"
        case .claudeDesktop: " · chat"
        }
        return [found.url.path(percentEncoded: false), found.version].compactMap { $0 }.joined(separator: " · ") + scope
    }
}

/// A command to copy, shown in full.
private struct CopyableCommand: View {
    var command: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            }
            Text(command)
                .font(.callout.monospaced())
                .foregroundStyle(.fg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.surface2, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        .padding(.vertical, 2)
    }
}

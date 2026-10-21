import AppKit
import SwiftUI

/// How to register the bundled `vaulthalla-mcp` bridge with an MCP client. Desktop only shows and copies the
/// commands; the operator runs them (docs/architecture.md §5).
enum AgentBridge {
    /// The name the clients list the server under.
    static let serverName = "vaulthalla-desktop"

    /// `Vaulthalla.app/Contents/Helpers/vaulthalla-mcp`.
    static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/vaulthalla-mcp", directoryHint: .notDirectory)
    }

    static func claudeCommand(_ path: String) -> String {
        "claude mcp add --scope user \(serverName) -- \(shellQuoted(path))"
    }

    static func codexCommand(_ path: String) -> String {
        "codex mcp add \(serverName) -- \(shellQuoted(path))"
    }

    /// For `~/.codex/config.toml` by hand. Codex gives a tool 60 s by default; the bridge allows a call 10 minutes.
    static func codexTOML(_ path: String) -> String {
        """
        [mcp_servers.\(serverName)]
        command = \(tomlQuoted(path))
        tool_timeout_sec = 600
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

struct AgentsSettingsView: View {
    private let helper = AgentBridge.helperURL

    private var path: String { helper.path(percentEncoded: false) }
    private var helperExists: Bool { FileManager.default.isExecutableFile(atPath: path) }
    private var installedInApplications: Bool { path.hasPrefix("/Applications/") }

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
                if !helperExists {
                    Label("This build doesn't contain the bridge.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StatusTone.warn.color)
                } else if !installedInApplications {
                    Text("Move Vaulthalla to Applications before registering it, so the path stays valid.")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                }
            } header: {
                Text("MCP bridge")
            } footer: {
                Text("Agents such as Claude Code and Codex start the bridge themselves. It reaches every node this "
                    + "Mac is paired with, through the same pairing the app uses; Vaulthalla doesn't need to be open.")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }

            Section("Claude Code") {
                CopyableCommand(command: AgentBridge.claudeCommand(path))
            }

            Section("Codex") {
                CopyableCommand(command: AgentBridge.codexCommand(path))
                CopyableCommand(command: AgentBridge.codexTOML(path), caption: "Or add to ~/.codex/config.toml:")
            }

            Section {
                Callout(tone: .info, systemImage: "lock.shield") {
                    Text("Agents act as you on each node")
                        .fontWeight(.semibold)
                        .foregroundStyle(.fg)
                    Text("On every node, an agent acts as the Vaulthalla account this Mac was paired by, with its "
                        + "permissions. Destructive commands wait for your approval in the agent, and agents can never "
                        + "export or import vault keys.")
                        .foregroundStyle(.fgMuted)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
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
            Button(caption == nil ? "Copy command" : "Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview("Agents") {
    AgentsSettingsView()
        .frame(width: 520)
        .preferredColorScheme(.dark)
}
#endif

import Foundation
@testable import VHAgents

/// A temporary HOME with stub `claude` and `codex` executables (plain sh scripts standing in for the real CLIs, which
/// tests never run). The stubs keep their registration in files under the HOME, record every argument vector
/// (NUL-separated, one `--END--` per call) and answer like the real CLIs do. A file `<tool>-mode` in the HOME makes a
/// stub misbehave: `old` (an older CLI without the subcommand), `hang`, `garbage`.
struct StubHome {
    let root: URL
    let home: URL
    let bin: URL
    let log: URL
    /// The bridge registrations point at: a path with spaces, quotes and shell syntax. The file is a script that
    /// prints its arguments, so the `.mcpb` launcher can be run against it.
    let bridge: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "vh-agents-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        bin = root.appending(path: "bin", directoryHint: .isDirectory)
        log = root.appending(path: "calls.log")
        bridge = root.appending(path: #"Vault "halla" it's $(touch pwned); `x`.app/Contents/Helpers/vaulthalla-mcp"#)
        let manager = FileManager.default
        for directory in [home, bin, root.appending(path: "work"), bridge.deletingLastPathComponent(),
                          home.appending(path: ".codex")] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Self.write(Self.claudeStub, to: bin.appending(path: "claude"))
        try Self.write(Self.codexStub, to: bin.appending(path: "codex"))
        try Self.write("#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\"; done\n", to: bridge)
        manager.createFile(atPath: log.path, contents: Data())
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var environment: AgentEnvironment {
        AgentEnvironment(
            home: home, searchPath: [bin.path],
            processEnvironment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "STUB_LOG": log.path,
                                 "CODEX_HOME": home.appending(path: ".codex").path],
            workingDirectory: root.appending(path: "work"), wellKnownDirectories: [])
    }

    func setMode(_ tool: String, _ mode: String?) throws {
        let url = home.appending(path: "\(tool)-mode")
        if let mode { try mode.write(to: url, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: url) }
    }

    /// Every call's argument vector, in order.
    var calls: [[String]] {
        let data = (try? Data(contentsOf: log)) ?? Data()
        var calls: [[String]] = [], current: [String] = []
        for field in data.split(separator: 0, omittingEmptySubsequences: false).dropLast() {
            let text = String(decoding: field, as: UTF8.self)
            if text == "--END--" { calls.append(current); current = [] } else { current.append(text) }
        }
        return calls
    }

    /// The calls that weren't `--version`.
    var subcommands: [[String]] { calls.filter { $0.first != "--version" } }

    var codexConfig: URL { home.appending(path: ".codex/config.toml") }
    var claudeState: URL { home.appending(path: "claude-registered.json") }

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static let prologue = #"""
        #!/bin/sh
        for a in "$@"; do printf '%s\0' "$a"; done >> "$STUB_LOG"; printf -- '--END--\0' >> "$STUB_LOG"
        mode=$(cat "$HOME/$(basename "$0")-mode" 2>/dev/null)
        [ "$mode" = hang ] && exec sleep 30
        """#

    static let claudeStub = prologue + #"""

        [ "$1" = --version ] && { echo "2.1.318 (Claude Code)"; exit 0; }
        [ "$mode" = old ] && { echo "error: unknown command 'mcp'" >&2; exit 1; }
        [ "$mode" = garbage ] && { echo "Something else entirely"; exit 0; }
        state="$HOME/claude-registered.json"
        case "$1 $2" in
        "mcp get")
          [ -f "$state" ] || { echo "No MCP server named \"$3\". Configured servers: other" >&2; exit 1; }
          printf '%s:\n  Scope: User config (available in all your projects)\n  Status: ✓ Connected\n  Type: stdio\n' "$3"
          printf '  Command: %s\n' "$(plutil -extract command raw -o - "$state")"
          n=$(plutil -extract args raw -o - "$state"); i=0; args=""
          while [ "$i" -lt "$n" ]; do args="$args${args:+ }$(plutil -extract "args.$i" raw -o - "$state")"; i=$((i+1)); done
          printf '  Args: %s\n  Environment:\n\nTo remove this server, run: claude mcp remove %s -s user\n' "$args" "$3"
          exit 0;;
        "mcp add-json")
          [ "$3 $4" = "--scope user" ] || { echo "wrong scope" >&2; exit 2; }
          [ -f "$state" ] && { echo "MCP server $5 already exists in user config" >&2; exit 1; }
          printf '%s' "$6" > "$state"; echo "Added stdio MCP server $5 to user config"; exit 0;;
        "mcp remove")
          [ "$3 $4" = "--scope user" ] || { echo "wrong scope" >&2; exit 2; }
          [ -f "$state" ] || { echo "No user-scoped MCP server found with name: $5" >&2; exit 1; }
          rm "$state"; echo "Removed MCP server $5 from user config"; exit 0;;
        esac
        echo "unexpected: $*" >&2; exit 2
        """#

    static let codexStub = prologue + #"""

        [ "$1" = --version ] && { echo "codex-cli 0.171.0"; exit 0; }
        [ "$mode" = old ] && { echo "error: unrecognized subcommand 'mcp'" >&2; exit 2; }
        [ "$mode" = garbage ] && { echo "not json"; exit 0; }
        cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"; state="$HOME/codex-registered.json"
        case "$1 $2" in
        "mcp get")
          [ "$4" = --json ] || { echo "expected --json" >&2; exit 2; }
          [ -f "$state" ] || { echo "Error: No MCP server named '$3' found." >&2; exit 1; }
          if grep -q '^tool_timeout_sec = 600$' "$cfg" 2>/dev/null; then
            plutil -insert tool_timeout_sec -float 600 -o - "$state"
          else
            cat "$state"
          fi
          exit 0;;
        "mcp add")
          name="$3"; [ "$4" = "--" ] || { echo "expected --" >&2; exit 2; }; shift 4
          printf '{"name":"%s","enabled":true,"transport":{"type":"stdio","command":"","args":[]}}' "$name" > "$state"
          plutil -replace transport.command -string "$1" "$state"; command="$1"; shift
          for a in "$@"; do plutil -insert transport.args -string "$a" -append "$state"; done
          escaped=$(printf '%s' "$command" | sed 's/\\/\\\\/g; s/"/\\"/g')
          { cat "$HOME/codex-prefix.toml" 2>/dev/null
            printf '[mcp_servers.%s]\ncommand = "%s"\nargs = ["--client", "codex"]\n' "$name" "$escaped"
            cat "$HOME/codex-suffix.toml" 2>/dev/null; } > "$cfg"
          echo "Added global MCP server '$name'."; exit 0;;
        "mcp remove")
          [ -f "$state" ] || { echo "No MCP server named '$3' found." >&2; exit 1; }
          rm "$state"; echo "Removed global MCP server '$3'."; exit 0;;
        esac
        echo "unexpected: $*" >&2; exit 2
        """#
}

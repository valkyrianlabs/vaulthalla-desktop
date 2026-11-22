public import Foundation
import VHCore

/// The MCP Bundle (`.mcpb`, https://github.com/modelcontextprotocol/mcpb) that adds the bridge to the Claude desktop
/// app: a zip with `manifest.json` at its root and a stdio server.
///
/// MANIFEST.md documents the server as bundled (`server.entry_point` and `mcp_config.command` relative to
/// `${__dirname}`) and says nothing about a command outside the bundle, so the bundle carries a three-line launcher,
/// `server/vaulthalla-mcp`, that execs the bridge inside Vaulthalla.app with `--client claude-desktop`. The bridge
/// itself stays in the app, where it is signed and has the keychain group; the launcher holds no key and no secret.
public struct MCPBundle: Sendable {
    public static let manifestVersion = "0.3"
    public static let launcherPath = "server/vaulthalla-mcp"

    public var bridge: URL
    /// The app's version (semver), the bundle's `version`.
    public var version: String
    /// The app icon as PNG, shown on Claude's install sheet (optional).
    public var iconPNG: Data?

    public init(bridge: URL, version: String, iconPNG: Data? = nil) {
        self.bridge = bridge
        self.version = version
        self.iconPNG = iconPNG
    }

    /// The launcher's exact text. The path is single-quoted (a `'` inside it closed, escaped and reopened), so no
    /// character of it is ever interpreted; the arguments are fixed.
    public var launcher: String {
        let quoted = "'" + bridge.path(percentEncoded: false).replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return """
            #!/bin/sh
            # Vaulthalla Desktop's MCP bridge lives inside Vaulthalla.app. Moved the app? Add it to Claude again.
            exec \(quoted) --client \(AgentClient.claudeDesktop.rawValue) "$@"

            """
    }

    public var manifest: [String: Any] {
        var manifest: [String: Any] = [
            "manifest_version": Self.manifestVersion,
            "name": agentServerName,
            "display_name": "Vaulthalla Desktop",
            "version": version,
            "description": "The Vaulthalla nodes this Mac is paired with, as tools.",
            "long_description": """
                Gives Claude the tools of every Vaulthalla node this Mac is paired with (and that is turned on for \
                Claude in Vaulthalla → Settings → Agents), through Vaulthalla Desktop's bridge. On each node Claude \
                acts as the Vaulthalla account this Mac was paired by, with its permissions. Destructive commands \
                wait for your approval, and vault keys are never reachable.
                """,
            "author": ["name": "Valkyrian Labs LLC", "url": "https://valkyrianlabs.com"],
            "homepage": "https://vaulthalla.io",
            "license": "AGPL-3.0-or-later",
            "server": [
                "type": "binary",
                "entry_point": Self.launcherPath,
                "mcp_config": [
                    "command": "${__dirname}/\(Self.launcherPath)",
                    "args": [String](),
                    "env": [String: String](),
                ],
            ],
            "tools_generated": true,
            "keywords": ["vaulthalla", "storage", "self-hosted"],
            "compatibility": ["platforms": ["darwin"]],
        ]
        if iconPNG != nil { manifest["icon"] = "icon.png" }
        return manifest
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case write(String)
        case zip(String)

        public var description: String {
            switch self {
            case .write(let why): "The bundle couldn't be written: \(why)"
            case .zip(let why): "The bundle couldn't be zipped: \(why)"
            }
        }
    }

    /// Writes `Vaulthalla Desktop.mcpb` into a new directory under `directory` (the system's temporary directory by
    /// default) and returns its URL. The staging folder is removed; only the `.mcpb` remains.
    public func build(in directory: URL = FileManager.default.temporaryDirectory,
                      runner: ProcessRunner = ProcessRunner()) async throws(Failure) -> URL {
        let manager = FileManager.default
        let root = directory.appending(path: "vaulthalla-mcpb-\(UUID().uuidString)", directoryHint: .isDirectory)
        let staging = root.appending(path: "bundle", directoryHint: .isDirectory)
        let output = root.appending(path: "Vaulthalla Desktop.mcpb", directoryHint: .notDirectory)
        do {
            try manager.createDirectory(at: staging.appending(path: "server"), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: manifest,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: staging.appending(path: "manifest.json"))
            let launcherURL = staging.appending(path: Self.launcherPath)
            try Data(launcher.utf8).write(to: launcherURL)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path(percentEncoded: false))
            if let iconPNG { try iconPNG.write(to: staging.appending(path: "icon.png")) }
        } catch {
            try? manager.removeItem(at: root)
            throw .write(error.localizedDescription)
        }
        defer { try? manager.removeItem(at: staging) }
        // ditto keeps the launcher's mode in the archive; --norsrc/--noextattr keep AppleDouble files out of it.
        let zipped: ProcessRunner.Output
        do {
            zipped = try await runner.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                          ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl",
                                           staging.path(percentEncoded: false), output.path(percentEncoded: false)],
                                          environment: [:], timeout: .seconds(30))
        } catch {
            try? manager.removeItem(at: root)
            throw .zip(error.description)
        }
        guard zipped.status == 0, !zipped.timedOut else {
            try? manager.removeItem(at: root)
            throw .zip(displayable(zipped.stderrText))
        }
        return output
    }
}

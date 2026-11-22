import Foundation
import Testing
import VHCore
@testable import VHAgents

@Suite(.timeLimit(.minutes(1))) struct MCPBundleTests {
    /// Builds the bundle, unzips it with the system's tools and reads it back against MANIFEST.md's required fields,
    /// then runs the unpacked launcher: it must exec the bridge at its exact path with `--client claude-desktop`.
    @Test func bundleHasTheRequiredFieldsAndALauncherThatExecsTheBridge() async throws {
        let stubs = try StubHome()
        defer { stubs.remove() }
        let icon = Data([0x89, 0x50, 0x4E, 0x47])
        let bundle = try await MCPBundle(bridge: stubs.bridge, version: "1.2.3", iconPNG: icon).build(in: stubs.root)
        #expect(bundle.pathExtension == "mcpb")
        // Only the bundle is left; the staging folder is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.deletingLastPathComponent().path)
            == ["Vaulthalla Desktop.mcpb"])

        let unpacked = stubs.root.appending(path: "unpacked", directoryHint: .isDirectory)
        let unzip = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                                  ["-x", "-k", bundle.path, unpacked.path],
                                                  environment: [:], timeout: .seconds(20))
        #expect(unzip.status == 0)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: unpacked.path))
            == ["manifest.json", "server", "icon.png"])

        let data = try Data(contentsOf: unpacked.appending(path: "manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Required: manifest_version, name, version, description, author.name, server (type, entry_point, mcp_config).
        #expect(manifest["manifest_version"] as? String == "0.3")
        #expect(manifest["name"] as? String == "vaulthalla-desktop")
        #expect(manifest["version"] as? String == "1.2.3")
        #expect((manifest["description"] as? String)?.isEmpty == false)
        #expect((manifest["author"] as? [String: Any])?["name"] as? String == "Valkyrian Labs LLC")
        let server = try #require(manifest["server"] as? [String: Any])
        #expect(server["type"] as? String == "binary")
        #expect(server["entry_point"] as? String == "server/vaulthalla-mcp")
        let config = try #require(server["mcp_config"] as? [String: Any])
        #expect(config["command"] as? String == "${__dirname}/server/vaulthalla-mcp")
        #expect(config["args"] as? [String] == [])
        #expect(manifest["icon"] as? String == "icon.png")
        #expect(try Data(contentsOf: unpacked.appending(path: "icon.png")) == icon)
        #expect((manifest["compatibility"] as? [String: Any])?["platforms"] as? [String] == ["darwin"])
        #expect(manifest["tools_generated"] as? Bool == true)
        // Nothing user-facing names a service that isn't available.
        #expect(!String(decoding: data, as: UTF8.self).contains("Cloud"))

        let launcher = unpacked.appending(path: "server/vaulthalla-mcp")
        let mode = try FileManager.default.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        let ran = try await ProcessRunner().run(launcher, ["extra arg"], environment: ["PATH": "/usr/bin:/bin"],
                                                directory: stubs.root, timeout: .seconds(10))
        #expect(ran.status == 0)
        #expect(ran.stdoutText == "[--client][claude-desktop][extra arg]")
        #expect(!FileManager.default.fileExists(atPath: stubs.root.appending(path: "pwned").path))
    }

    @Test func claudeDesktopReadsItsInstallsReadOnly() async throws {
        let stubs = try StubHome()
        defer { stubs.remove() }
        let app = stubs.root.appending(path: "Claude.app", directoryHint: .isDirectory)
        var claude = ClaudeDesktopIntegration(environment: stubs.environment, version: "1.2.3")
        claude.locateApplication = { _ in app }
        var other = claude
        other.locateApplication = { _ in nil }
        #expect(await other.status(bridge: stubs.bridge) == .notInstalled)

        // No extensions folder yet: not added.
        #expect(await claude.status(bridge: stubs.bridge).registration == .notAdded)

        let installed = claude.extensionsDirectory.appending(path: "local.mcpb.valkyrian-labs-llc.vaulthalla-desktop")
        try FileManager.default.createDirectory(at: installed.appending(path: "server"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude.extensionsDirectory.appending(path: "ant.dir.other"),
                                                withIntermediateDirectories: true)
        try #"{"name":"vaulthalla-desktop"}"#.write(to: installed.appending(path: "manifest.json"), atomically: true,
                                                    encoding: .utf8)
        let moved = MCPBundle(bridge: URL(fileURLWithPath: "/Users/x/Down'loads/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"),
                              version: "1.2.3").launcher
        try moved.write(to: installed.appending(path: MCPBundle.launcherPath), atomically: true, encoding: .utf8)
        #expect(await claude.status(bridge: stubs.bridge).registration
            == .stale(registered: "/Users/x/Down'loads/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"))

        try MCPBundle(bridge: stubs.bridge, version: "9.9.9").launcher
            .write(to: installed.appending(path: MCPBundle.launcherPath), atomically: true, encoding: .utf8)
        #expect(await claude.status(bridge: stubs.bridge).registration == .current)

        guard case .openBundle(let bundle, let application) = await claude.add(bridge: stubs.bridge) else {
            Issue.record("no bundle"); return
        }
        #expect(application == app)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
        #expect(await claude.remove(bridge: stubs.bridge) == .manual(ClaudeDesktopIntegration.removeInstructions))
    }
}

@Suite(.timeLimit(.minutes(1))) struct ProcessAndEnvironmentTests {
    @Test func argumentsAreNeverInterpreted() async throws {
        let stubs = try StubHome()
        defer { stubs.remove() }
        let tricky = [#"a b"#, #""quoted""#, "it's", "$(touch pwned)", "`touch pwned`", "; touch pwned", "*", "", "\n"]
        let output = try await ProcessRunner().run(stubs.bridge, tricky, environment: [:], directory: stubs.root,
                                                   timeout: .seconds(10))
        #expect(output.status == 0)
        #expect(output.stdoutText == tricky.map { "[\($0)]" }.joined())
        #expect(!FileManager.default.fileExists(atPath: stubs.root.appending(path: "pwned").path))
    }

    @Test func deadlinesStartFailuresAndLimits() async throws {
        let runner = ProcessRunner()
        let start = ContinuousClock.now
        let slow = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: [:],
                                        timeout: .milliseconds(300))
        #expect(slow.timedOut)
        #expect(ContinuousClock.now - start < .seconds(10))

        await #expect(throws: ProcessRunner.Failure.self) {
            _ = try await runner.run(URL(fileURLWithPath: "/nonexistent/claude"), [], environment: [:],
                                     timeout: .seconds(1))
        }
        let big = try await runner.run(URL(fileURLWithPath: "/usr/bin/yes"), [], environment: [:],
                                       timeout: .milliseconds(500))
        #expect(big.stdout.count <= ProcessRunner.outputLimit)
        let failing = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2; exit 3"],
                                           environment: [:], timeout: .seconds(5))
        #expect(failing.status == 3 && failing.stdoutText == "out\n" && failing.stderrText == "err\n")
    }

    @Test func locatesWellKnownLocationsFirstThenThePath() throws {
        let stubs = try StubHome()
        defer { stubs.remove() }
        let local = stubs.home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        var environment = stubs.environment
        environment.wellKnownDirectories = [local.path, "relative/ignored"]
        #expect(environment.locate("claude")?.url == stubs.bin.appending(path: "claude"))
        #expect(environment.locate("claude")?.discovery == .loginShellPath)
        try StubHome.write("#!/bin/sh\n", to: local.appending(path: "claude"))
        #expect(environment.locate("claude")?.url == local.appending(path: "claude"))
        #expect(environment.locate("claude")?.discovery == .wellKnownLocation)
        // A directory or a non-executable file of that name doesn't count.
        try FileManager.default.createDirectory(at: stubs.bin.appending(path: "nothing"), withIntermediateDirectories: true)
        #expect(environment.locate("nothing") == nil)
        #expect(AgentEnvironment.defaultWellKnownDirectories(home: stubs.home).contains("/opt/homebrew/bin"))
    }

    @Test func loginShellPathIsReadFromTheMarkedLineOnly() {
        let output = "Welcome!\n/etc/motd noise\n\n__VAULTHALLA_PATH__/opt/homebrew/bin:relative:/usr/bin:/opt/homebrew/bin\n"
        #expect(AgentEnvironment.parsePathOutput(output) == ["/opt/homebrew/bin", "/usr/bin"])
        #expect(AgentEnvironment.parsePathOutput("no marker") == [])
        #expect(!AgentEnvironment.printPathProgram.contains("/Users"))
    }

    @Test func bridgeLocationBlocksPathsThatWontLast() throws {
        let stubs = try StubHome()
        defer { stubs.remove() }
        #expect(BridgeLocation.check(stubs.root.appending(path: "missing")) == .missing)
        // In a temporary folder.
        guard case .unstable = BridgeLocation.check(stubs.bridge) else { Issue.record(); return }
        #expect(!BridgeLocation.check(stubs.bridge).allowsAdding)
        #expect(BridgeLocation.stable(inApplications: false).allowsAdding)
    }

    @Test func classifiesRegistrations() {
        let bridge = BridgeCommand(executable: URL(fileURLWithPath: "/Applications/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"),
                                   client: .codex)
        #expect(bridge.classify(command: bridge.path, arguments: ["--client", "codex"]) == .current)
        #expect(bridge.classify(command: "/Applications/./Vaulthalla.app/Contents/Helpers/vaulthalla-mcp",
                                arguments: ["--client", "codex"]) == .current)
        #expect(bridge.classify(command: bridge.path, arguments: []) == .handMade)
        #expect(bridge.classify(command: bridge.path, arguments: ["--client", "claude-code"])
            == .stale(registered: bridge.path + " --client claude-code"))
        #expect(bridge.classify(command: "/elsewhere/vaulthalla-mcp", arguments: []) == .stale(registered: "/elsewhere/vaulthalla-mcp"))
    }
}

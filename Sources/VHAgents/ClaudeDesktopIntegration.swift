public import Foundation
import CoreServices
public import VHCore

/// The Claude desktop app's chat. Local servers install from an MCP Bundle, opened with Claude, whose own install
/// sheet finishes the job; there is no CLI, deep link or documented configuration to write, so:
///
/// - present: the app found by its bundle id (Launch Services), else in /Applications or ~/Applications.
/// - added: best effort, read-only. Claude unpacks installed bundles under its application support
///   (`Claude Extensions/<id>/`, undocumented); a folder there whose `manifest.json` is named `vaulthalla-desktop`
///   and whose launcher is the one this app would write means it is added. Anything Vaulthalla can't read there is
///   ``Registration/unknown``, never a guess.
/// - add: ``MCPBundle/build(in:runner:)``, then the app opens it with Claude.
/// - remove: only in Claude (Settings → Extensions).
public struct ClaudeDesktopIntegration: AgentAppIntegration {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    public let client = AgentClient.claudeDesktop
    public var environment: AgentEnvironment
    /// The app's version for the bundle.
    public var version: String
    public var iconPNG: Data?
    /// Finds Claude.app; replaceable in tests.
    public var locateApplication: @Sendable (AgentEnvironment) -> URL? = ClaudeDesktopIntegration.defaultLocation

    public init(environment: AgentEnvironment, version: String, iconPNG: Data? = nil) {
        self.environment = environment
        self.version = version
        self.iconPNG = iconPNG
    }

    public var extensionsDirectory: URL {
        environment.home.appending(path: "Library/Application Support/Claude/Claude Extensions", directoryHint: .isDirectory)
    }

    public static let removeInstructions =
        "Remove it in Claude: Settings → Extensions → Vaulthalla Desktop → Uninstall."

    public static func defaultLocation(_ environment: AgentEnvironment) -> URL? {
        if let urls = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?
            .takeRetainedValue() as? [URL], let first = urls.first(where: { !$0.path.contains("/AppTranslocation/") }) {
            return first
        }
        for candidate in [URL(fileURLWithPath: "/Applications/Claude.app"),
                          environment.home.appending(path: "Applications/Claude.app")] {
            if Bundle(url: candidate)?.bundleIdentifier == bundleIdentifier { return candidate }
        }
        return nil
    }

    private func found() -> FoundApp? {
        guard let url = locateApplication(environment) else { return nil }
        let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
        return FoundApp(url: url, discovery: .applicationRegistry, version: version.map { displayable($0, limit: 40) })
    }

    public func status(bridge: URL) async -> AgentAppStatus {
        guard let found = found() else { return .notInstalled }
        return .installed(found, .init(registration: installedRegistration(bridge: bridge)))
    }

    /// What Claude's extension folder says, read-only.
    func installedRegistration(bridge: URL) -> Registration {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: extensionsDirectory, includingPropertiesForKeys: nil)
        else {
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: extensionsDirectory.path(percentEncoded: false),
                                            isDirectory: &isDirectory)
            return exists ? .unknown : .notAdded
        }
        let expected = MCPBundle(bridge: bridge, version: version).launcher
        var registration = Registration.notAdded
        for folder in folders {
            let manifestURL = folder.appending(path: "manifest.json")
            guard let data = try? Data(contentsOf: manifestURL), data.count < 1 << 20,
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  manifest["name"] as? String == agentServerName
            else { continue }
            let launcher = (try? Data(contentsOf: folder.appending(path: MCPBundle.launcherPath)))
                .map { String(decoding: $0, as: UTF8.self) }
            if launcher == expected { return .current }
            registration = .stale(registered: Self.registeredPath(in: launcher) ?? folder.lastPathComponent)
        }
        return registration
    }

    /// The bridge path a launcher this app wrote execs, for display.
    static func registeredPath(in launcher: String?) -> String? {
        guard let line = launcher?.split(separator: "\n").first(where: { $0.hasPrefix("exec '") }) else { return nil }
        guard let end = line.range(of: "' --client") else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 6) ..< end.lowerBound])
            .replacingOccurrences(of: #"'\''"#, with: "'")
    }

    public func add(bridge: URL) async -> AgentActionOutcome {
        guard let application = found()?.url else { return .failed("Claude isn't installed.") }
        do {
            let bundle = try await MCPBundle(bridge: bridge, version: version, iconPNG: iconPNG)
                .build(runner: environment.runner)
            return .openBundle(bundle, application: application)
        } catch {
            return .failed(error.description)
        }
    }

    public func remove(bridge: URL) async -> AgentActionOutcome {
        .manual(Self.removeInstructions)
    }
}

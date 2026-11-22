public import Foundation
import Synchronization

/// Where AI apps' command-line tools are looked for and what they run with. The app passes ``current()``; tests pass a
/// temporary HOME and a directory of stub executables.
public struct AgentEnvironment: Sendable {
    /// The user's home (`~/.codex`, Claude's application support, `~/.local/bin` derive from it).
    public var home: URL
    /// Directories searched after the well-known ones, in order (the login shell's PATH).
    public var searchPath: [String]
    /// The environment the tools run with: the app's own, with PATH set to the search path (a GUI app's PATH is
    /// minimal, and a CLI may need its runtime from the user's PATH).
    public var processEnvironment: [String: String]
    /// The directory the tools run in: an empty one, so no project's local or `.mcp.json` servers are involved.
    public var workingDirectory: URL
    /// The well-known install locations, searched first (``defaultWellKnownDirectories(home:)``).
    public var wellKnownDirectories: [String]
    public var runner: ProcessRunner = ProcessRunner()

    public init(home: URL, searchPath: [String], processEnvironment: [String: String], workingDirectory: URL,
                wellKnownDirectories: [String]? = nil) {
        self.home = home
        self.searchPath = searchPath
        self.processEnvironment = processEnvironment
        self.workingDirectory = workingDirectory
        self.wellKnownDirectories = wellKnownDirectories ?? Self.defaultWellKnownDirectories(home: home)
    }

    /// `~/.local/bin` (Claude Code's native installer), `~/.claude/local` (its older local install), Homebrew's two
    /// prefixes (Codex's cask, npm under Homebrew's node).
    public static func defaultWellKnownDirectories(home: URL) -> [String] {
        [
            home.appending(path: ".local/bin").path(percentEncoded: false),
            home.appending(path: ".claude/local").path(percentEncoded: false),
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
    }

    /// The first executable file named `name` in the well-known directories, then the search path.
    public func locate(_ name: String) -> (url: URL, discovery: FoundApp.Discovery)? {
        precondition(!name.contains("/"))
        let manager = FileManager.default
        for (directories, discovery) in [(wellKnownDirectories, FoundApp.Discovery.wellKnownLocation),
                                         (searchPath, .loginShellPath)] {
            for directory in directories where directory.hasPrefix("/") {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true).appending(path: name)
                var isDirectory: ObjCBool = false
                let path = candidate.path(percentEncoded: false)
                if manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                   manager.isExecutableFile(atPath: path) {
                    return (candidate, discovery)
                }
            }
        }
        return nil
    }

    /// Runs a located tool with an argument array.
    func run(_ executable: URL, _ arguments: [String], timeout: Duration) async throws(ProcessRunner.Failure)
        -> ProcessRunner.Output
    {
        try await runner.run(executable, arguments, environment: processEnvironment, directory: workingDirectory,
                             timeout: timeout)
    }

    // MARK: - The running app's

    private static let resolved = Mutex<[String]?>(nil)

    /// This user's environment: the home directory, and the login shell's PATH (asked once per process).
    public static func current() async -> AgentEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let searchPath: [String]
        if let cached = resolved.withLock({ $0 }) {
            searchPath = cached
        } else {
            searchPath = await loginShellPath()
            resolved.withLock { $0 = searchPath }
        }
        var environment = ProcessInfo.processInfo.environment
        var path = searchPath
        for fallback in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !path.contains(fallback) { path.append(fallback) }
        environment["PATH"] = path.joined(separator: ":")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "vaulthalla-agents", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AgentEnvironment(home: home, searchPath: searchPath, processEnvironment: environment,
                                workingDirectory: directory)
    }

    /// The fixed program a login shell is asked to run. It names nothing from outside: no path, no argument.
    static let printPathProgram = #"printf '\n__VAULTHALLA_PATH__%s\n' "$PATH""#

    /// The login shell's PATH: the user's shell (from the user database), started as a login shell with the fixed
    /// ``printPathProgram``. Its output is data: only the marked line is read, and only absolute directories kept.
    static func loginShellPath(runner: ProcessRunner = ProcessRunner()) async -> [String] {
        guard let entry = getpwuid(getuid()), let shellPointer = entry.pointee.pw_shell else { return [] }
        let shell = String(cString: shellPointer)
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { return [] }
        let output = try? await runner.run(URL(fileURLWithPath: shell), ["-l", "-c", printPathProgram],
                                           environment: ProcessInfo.processInfo.environment, timeout: .seconds(5))
        guard let output, output.status == 0, !output.timedOut else { return [] }
        return parsePathOutput(output.stdoutText)
    }

    static func parsePathOutput(_ text: String) -> [String] {
        let marker = "__VAULTHALLA_PATH__"
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return [] }
        var seen = Set<String>()
        return line.dropFirst(marker.count).split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }
}

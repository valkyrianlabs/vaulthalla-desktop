import Foundation
@testable import VHOnePassword

/// The real Go helper, built once per test run with `-tags fake` (Helpers/vaulthalla-1password/fake_on.go) and
/// started with VH_OP_FAKE=1: an in-memory 1Password plus fault-injection ops. Testing against it rather than a
/// Swift stub proves the protocol both sides actually speak (field names, base64 key encoding, error codes, null
/// ids, framing) and exercises the helper's version rules end to end. The fake code is compiled only with the
/// `fake` tag, so release binaries can't be switched into it.
///
/// Needs a Go toolchain (`go` on PATH or in a standard location). Without one the integration suite is skipped;
/// with one, a build failure fails the tests.
enum FakeHelper {
    struct BuildFailure: Error, CustomStringConvertible {
        let description: String
    }

    static let sourceDirectory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Helpers/vaulthalla-1password", directoryHint: .isDirectory)

    static let goExecutable: URL? = {
        let environment = ProcessInfo.processInfo.environment
        var candidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/go" }
        candidates += ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"]
        if let explicit = environment["GO"] { candidates.insert(explicit, at: 0) }
        return candidates.lazy.map { URL(filePath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    static var goAvailable: Bool { goExecutable != nil }

    static let built: Result<URL, BuildFailure> = {
        guard let go = goExecutable else { return .failure(BuildFailure(description: "no Go toolchain")) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "vh-op-fake-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "vaulthalla-1password-fake")

        let process = Process()
        process.executableURL = go
        process.arguments = ["build", "-tags", "fake", "-o", output.path, "."]
        process.currentDirectoryURL = sourceDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["CGO_ENABLED"] = "0" // the fake never loads 1Password's library
        // A build cache of our own under the temporary directory, kept across runs: the user's
        // ~/Library/Caches/go-build may not be writable here (sandboxed agents and CI runners).
        if environment["GOCACHE"] == nil {
            environment["GOCACHE"] = FileManager.default.temporaryDirectory.appending(path: "vh-op-gocache").path
        }
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(BuildFailure(description: "couldn't run go: \(error)"))
        }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failure(BuildFailure(description: "go build failed: \(String(decoding: message, as: UTF8.self))"))
        }
        return .success(output)
    }()

    static func configuration(
        timeout: Duration = .seconds(20), maxConsecutiveCrashes: Int = 3
    ) throws -> OnePasswordHelper.Configuration {
        OnePasswordHelper.Configuration(
            executableURL: try built.get(), environment: ["VH_OP_FAKE": "1"], requestTimeout: timeout,
            maxConsecutiveCrashes: maxConsecutiveCrashes
        )
    }

    static func helper(timeout: Duration = .seconds(20), maxConsecutiveCrashes: Int = 3) throws -> OnePasswordHelper {
        OnePasswordHelper(configuration: try configuration(timeout: timeout, maxConsecutiveCrashes: maxConsecutiveCrashes))
    }
}

/// Whether a process still exists (and isn't a zombie Foundation has yet to reap).
func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

/// Waits up to `seconds` for `condition`.
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

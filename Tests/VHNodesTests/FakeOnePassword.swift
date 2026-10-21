import Foundation
import VHCore
@testable import VHOnePassword

/// The 1Password helper's fake build (in-memory 1Password, `VH_OP_FAKE=1`) for the key backup tests, built once per
/// run like VHOnePasswordTests' `FakeHelper`. Nothing here contacts the real 1Password app.
enum FakeOnePassword {
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
            .appending(path: "vh-op-fake-nodes-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "vaulthalla-1password-fake")
        let process = Process()
        process.executableURL = go
        process.arguments = ["build", "-tags", "fake", "-o", output.path, "."]
        process.currentDirectoryURL = sourceDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["CGO_ENABLED"] = "0"
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

    static func helper() throws -> OnePasswordHelper {
        OnePasswordHelper(configuration: .init(
            executableURL: try built.get(), environment: ["VH_OP_FAKE": "1"], requestTimeout: .seconds(20)))
    }
}

extension OnePasswordHelper {
    private struct Check: Decodable, Sendable { let key_check: String }

    /// A test key's check, from the fake build (`fake.key_check`): Swift never implements BLAKE2b.
    func testKeyCheck(_ key: [UInt8], vault: Int64, version: Int) async throws -> String {
        let secret = SecretBytes(key)
        return try await send(op: "fake.key_check", as: Check.self) { w in
            w.key("key_b64")
            w.base64(secret)
            w.field("vault_uuid", String(vault))
            w.field("version", version)
        }.key_check
    }

    /// Fake-mode writes so far (creates + puts).
    func testWrites() async throws -> Int {
        struct Stats: Decodable, Sendable { let writes: Int }
        return try await send(op: "fake.stats", as: Stats.self).writes
    }
}

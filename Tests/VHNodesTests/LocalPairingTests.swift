import Foundation
import Testing
@testable import VHNodes

/// Pairing with this Mac's server through `vh` (desktop#7): approve only what the daemon's own view confirms.
@Suite struct LocalPairingTests {
    private static let deviceID = String(repeating: "ab", count: 32)

    /// A scripted `vh`: answers by subcommand, records every call.
    private final class FakeVH: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var answers: [String: LocalPairing.Output]

        init(_ answers: [String: LocalPairing.Output]) { self.answers = answers }

        var calls: [[String]] { lock.withLock { _calls } }

        var pairing: LocalPairing {
            LocalPairing { [self] arguments in
                lock.withLock { _calls.append(arguments) }
                return answers[arguments.prefix(2).joined(separator: " ")] ?? .init(status: 0, stdout: "")
            }
        }
    }

    private static func pending(deviceID: String = Self.deviceID, choices: [String]) -> LocalPairing.Output {
        let json = """
        {"window": {"expires_at": 1790000600}, "requests": [
          {"request_id": "r-other", "device_id": "\(String(repeating: "cd", count: 32))", "code_choices": ["111111", "222222", "333333"]},
          {"request_id": "r-1", "name": "Studio Mac", "platform": "macOS", "app_version": "0.4.0", "source_ip": "127.0.0.1",
           "device_id": "\(deviceID)", "code_choices": \(choices.description), "created_at": 1790000000, "expires_at": 1790000300}
        ]}
        """
        return .init(status: 0, stdout: json)
    }

    @Test func approvesThisMacsRequestWithItsCode() async throws {
        let vh = FakeVH(["device pending": Self.pending(choices: ["019337", "482913", "760001"])])
        try await vh.pairing.openWindow()
        try await vh.pairing.approve(deviceID: Self.deviceID.uppercased(), code: "482913")
        await vh.pairing.closeWindow()
        #expect(vh.calls == [["device", "pair"], ["device", "pending", "--json"],
                             ["device", "approve", "r-1", "--code", "482913"], ["device", "pair", "--close"]])
    }

    @Test func deniesWhenTheServerShowsOtherCodes() async {
        let vh = FakeVH(["device pending": Self.pending(choices: ["019337", "760001", "555555"])])
        await #expect(throws: LocalPairing.Failure.codeMismatch) {
            try await vh.pairing.approve(deviceID: Self.deviceID, code: "482913")
        }
        #expect(vh.calls.last == ["device", "deny", "r-1"])
        #expect(!vh.calls.contains { $0.contains("approve") })
    }

    @Test func refusesWhenNoRequestCarriesThisMacsKey() async {
        let vh = FakeVH(["device pending": Self.pending(deviceID: String(repeating: "ef", count: 32), choices: ["482913"])])
        await #expect(throws: LocalPairing.Failure.requestNotFound) {
            try await vh.pairing.approve(deviceID: Self.deviceID, code: "482913")
        }
        #expect(!vh.calls.contains { $0.contains("approve") || $0.contains("deny") })
    }

    @Test func passesOnWhatVHRefusedWith() async {
        let message = "permission denied: this user is not in the 'vaulthalla' group"
        let vh = FakeVH(["device pair": .init(status: 77, stdout: "", stderr: message + "\n")])
        await #expect(throws: LocalPairing.Failure.refused(message)) { try await vh.pairing.openWindow() }
    }

    @Test func unreadablePendingIsRefused() async {
        let vh = FakeVH(["device pending": .init(status: 0, stdout: "No pairing window of yours is open.")])
        await #expect(throws: LocalPairing.Failure.unreadable) {
            try await vh.pairing.approve(deviceID: Self.deviceID, code: "482913")
        }
    }

    @Test(arguments: [
        ("127.0.0.1", true), ("::1", true), ("[::1]", true), ("localhost", true), ("studio", true),
        ("studio.local", true), ("Studio.local.", true), ("10.0.0.5", true), ("10.0.0.11", false),
        ("studio.example.com", false), ("vh.local", false),
    ])
    func recognizesThisMac(host: String, expected: Bool) {
        #expect(LocalPairing.isThisMac(host, hostNames: ["Studio.local"], addresses: ["10.0.0.5", "fe80::1"]) == expected)
    }
}

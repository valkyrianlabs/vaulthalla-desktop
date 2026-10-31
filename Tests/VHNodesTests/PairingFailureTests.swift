import Testing
import VHTransport
@testable import VHNodes

/// How the daemon's pairing refusals become `PairingFailure`s. The pairing exchange itself runs against a real daemon
/// in the live suite (docs/interop-testing.md); the code and commitment math are VHIdentityTests' `PairingCodeTests`.
@Suite struct PairingFailureTests {
    @Test func refusalCodesMapToFailures() {
        #expect(PairingFailure(WsError.refused(code: "rate_limited", message: "x")) == .rateLimited)
        #expect(PairingFailure(WsError.refused(code: "no_pairing_window", message: "x")) == .noPairingWindow)
        #expect(PairingFailure(WsError.refused(code: "device_unknown", message: "x")) == .requestUnknown)
        #expect(PairingFailure(WsError.conflict("x")) == .alreadyPaired)
        #expect(PairingFailure(WsError.invalid("x")) == .rejected)
        #expect(PairingFailure(WsError.error("boom")) == .server("boom"))
    }
}

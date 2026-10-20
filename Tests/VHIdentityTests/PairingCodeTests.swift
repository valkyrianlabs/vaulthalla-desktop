import Foundation
import Testing
import VHIdentity

/// Test vectors from docs/pairing.md §8, computed independently with Python's hashlib.
@Suite struct PairingCodeTests {
    let server = Data.counting(from: 0x00)
    let device = Data.counting(from: 0x20)
    let deviceNonce = Data.counting(from: 0x40)
    let serverNonce = Data.counting(from: 0x60)

    @Test func vector1() throws {
        let code = try PairingCode(
            serverSPKISHA256: server, deviceSPKISHA256: device, deviceNonce: deviceNonce, serverNonce: serverNonce)
        #expect(code.digits == "680179")
        #expect(code.formatted == "680 179")
        #expect("\(code)" == "680 179")
    }

    @Test func vector2KeepsLeadingZero() throws {
        var nonce = serverNonce
        nonce[31] = 0x04
        let code = try PairingCode(
            serverSPKISHA256: server, deviceSPKISHA256: device, deviceNonce: deviceNonce, serverNonce: nonce)
        #expect(code.digits == "022592")
        #expect(code.formatted == "022 592")
    }

    @Test func commitmentVector() throws {
        let commitment = try PairingCode.commitment(deviceSPKISHA256: device, deviceNonce: deviceNonce)
        #expect(commitment.hex == "eed843e2020fa269fbad8e1f326b441a7800a93bd5d985e1ee85920e7b853d32")
    }

    @Test func everyInputChangesTheCode() throws {
        let base = try PairingCode(
            serverSPKISHA256: server, deviceSPKISHA256: device, deviceNonce: deviceNonce, serverNonce: serverNonce)
        // Swapping the two SPKIs (a MITM's view of the roles) must not reproduce the code.
        let swapped = try PairingCode(
            serverSPKISHA256: device, deviceSPKISHA256: server, deviceNonce: deviceNonce, serverNonce: serverNonce)
        #expect(swapped != base)
    }

    @Test func rejectsWrongLengths() {
        #expect(throws: IdentityError.invalidLength(field: "nonce_server", expected: 32, actual: 31)) {
            try PairingCode(
                serverSPKISHA256: server, deviceSPKISHA256: device, deviceNonce: deviceNonce,
                serverNonce: serverNonce.prefix(31))
        }
        #expect(throws: IdentityError.invalidLength(field: "device_spki_sha256", expected: 32, actual: 0)) {
            try PairingCode.commitment(deviceSPKISHA256: Data(), deviceNonce: deviceNonce)
        }
    }

    @Test func noncesAreFreshAndSized() {
        let first = PairingCode.makeNonce()
        let second = PairingCode.makeNonce()
        #expect(first.count == 32)
        #expect(first != second)
    }
}

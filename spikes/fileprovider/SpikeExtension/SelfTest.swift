// THROWAWAY SPIKE: the self-test the constructor in selftest_hook.c runs (sandboxed, extension signature).
import Foundation
import Security

@_cdecl("spike_extension_selftest")
func spikeExtensionSelfTest(_ sandboxed: Int32) {
    Spike.log("selftest: sandbox_check=\(sandboxed) HOME=\(NSHomeDirectory()) bundle=\(Bundle.main.bundleIdentifier ?? "?")")
    // The sandbox must refuse the real home (outside the container).
    let real = "/Users/\(NSUserName())/.ssh"
    Spike.log("selftest: list \(real): \((try? FileManager.default.contentsOfDirectory(atPath: real)).map { "ALLOWED (\($0.count) entries)" } ?? "denied")")
    let expected = Spike.container.flatMap { try? String(contentsOf: $0.appending(path: "expected-secret.txt"), encoding: .utf8) }
    let (status, value, group) = Spike.readSecret()
    Spike.log("selftest: group container \(Spike.container?.path ?? "nil") readable=\(expected != nil)")
    Spike.log("selftest: keychain generic password: \(Spike.describe(status)) group=\(group ?? "nil") matches=\(value != nil && value == expected)")
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let entries = try await Backend.shared.list("/")
            let docs = try await Backend.shared.list("/docs")
            let (blob, code) = try await Backend.shared.download("/docs/blob.bin")
            let seeded = pattern(count: 65536, block: 0, blockMix: 0)
            Spike.log("selftest: / = \(entries.map(\.name)), /docs = \(docs.map(\.name)); blob.bin \(code) \(blob.count) bytes, equals seeded pattern: \(blob == seeded)")
            let (part, partCode) = try await Backend.shared.download("/big.bin", range: 20 * 1048576...(21 * 1048576 - 1))
            let expectedPart = pattern(count: 1048576, block: 20, blockMix: 31)
            Spike.log("selftest: big.bin range 20MiB+1MiB \(partCode) \(part.count) bytes, equals pattern: \(part == expectedPart)")
        } catch {
            Spike.log("selftest: network FAILED: \(error)")
        }
        done.signal()
    }
    done.wait()
}

/// Byte i of the seeded files: (7i + 3 + block*blockMix) mod 256.
func pattern(count: Int, block: Int, blockMix: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let offset = block * blockMix + 3
    for i in 0..<count { bytes[i] = UInt8(truncatingIfNeeded: (i &* 7 &+ offset) & 0xff) }
    return Data(bytes)
}

import Foundation
import Testing
@testable import VHTransport

/// The resumable uploader's own arithmetic (the server's transfer-protocol.md §3): error codes, stored-range
/// bookkeeping, part carving within the node's limits, and the headers it reads and writes. The session exchange
/// itself runs against a real daemon in the live suite (docs/interop-testing.md).
@Suite struct ResumableUploadTests {
    static let mib = 1 << 20

    @Test func errorCodesMapWithoutReadingWords() {
        func body(_ code: String) -> Data { Data(#"{"error":{"code":"\#(code)","message":"already exists"}}"#.utf8) }
        #expect(TransferError.coded(status: 409, body: body("part_overlap")) == .status(409, "already exists"))
        #expect(TransferError.coded(status: 412, body: body("precondition_failed"), etag: "\"e\"")
                == .preconditionFailed(currentVersion: "\"e\""))
        #expect(TransferError.coded(status: 413, body: body("file_too_large")) == .fileTooLarge)
        #expect(TransferError.coded(status: 507, body: body("insufficient_storage")) == .quotaExceeded)
        #expect(TransferError.coded(status: 429, body: body("too_many_parts_in_flight")) == .busy)
        #expect(TransferError.coded(status: 404, body: body("not_found")) == .uploadExpired)
        #expect(TransferError.coded(status: 403, body: Data()) == .forbidden)
        #expect(TransferError.coded(status: nil, code: "key_rotated", message: nil) == .keyRotated)
        #expect(TransferError.coded(status: nil, code: "quota_exceeded", message: nil) == .quotaExceeded)
        #expect(TransferError.keyRotated.message.contains("key changed"))
    }

    @Test func byteRangesCoalesceAndFindGaps() {
        var ranges = ByteRanges(wire: [[10, 20], [0, 5], [5, 8], [30, 40]])
        #expect(ranges.wire == [[0, 8], [10, 20], [30, 40]])
        #expect(ranges.gaps(upTo: 50) == [8..<10, 20..<30, 40..<50])
        ranges.insert(8..<30)
        #expect(ranges.wire == [[0, 40]])
        #expect(ranges.byteCount == 40)
        #expect(ranges.contains(3..<39) && !ranges.contains(39..<41))
        #expect(ByteRanges(wire: [[5, 5], [9, 3], [1]]).isEmpty)
    }

    /// Parts never leave a sliver below the node's minimum in front of a stored range.
    @Test func partsAreCarvedWithinTheNodesLimits() {
        let mib = Int64(Self.mib)
        let limits = TransferTuner.Limits(minBytes: mib, maxBytes: 8 * mib, defaultBytes: 4 * mib, maxInFlight: 4)
        let file = FileRun(index: 0, fileID: "f0", name: "a", source: URL(filePath: "/dev/null"), size: 20 * mib,
                           identity: nil, stored: ByteRanges([(4 * mib + mib / 2)..<(10 * mib)]))
        let run = SessionRun(uploadID: "u", limits: limits, files: [file])
        // The gap before the stored range is 4.5 MiB: a 4 MiB part would leave 0.5 MiB, so it takes all of it.
        #expect(run.carve(file, partBytes: 4 * mib) == 0..<(4 * mib + mib / 2))
        var second = file
        second.inFlight = [0..<(4 * mib + mib / 2)]
        #expect(run.carve(second, partBytes: 4 * mib) == (10 * mib)..<(14 * mib))
        // The file's last part may be short.
        var third = second
        third.inFlight.append((10 * mib)..<(19 * mib + 1))
        #expect(run.carve(third, partBytes: 64 * mib) == (19 * mib + 1)..<(20 * mib))
        // Larger than the node's maximum: clamped.
        #expect(run.carve(second, partBytes: 64 * mib)?.count == Int(8 * mib))
        // A stranded sliver can't be sent: empty.
        let stranded = FileRun(index: 0, fileID: "f0", name: "a", source: URL(filePath: "/dev/null"), size: 20 * mib,
                               identity: nil, stored: ByteRanges([0..<(4 * mib), (4 * mib + 10)..<(20 * mib)]))
        #expect(run.carve(stranded, partBytes: 4 * mib)?.isEmpty == true)
    }

    @Test func retryAfterAndDigestHeaders() {
        #expect(ResumableUploader.retryAfter("2") == .seconds(2))
        #expect(ResumableUploader.retryAfter("0.05") == .milliseconds(50))
        #expect(ResumableUploader.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == .seconds(1))
        #expect(ResumableUploader.retryAfter(nil) == nil)
        let hex = String(repeating: "00", count: 32)
        #expect(ResumableUploader.contentDigest(hex: hex) == "sha-256=:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=:")
        #expect(ResumableUploader.isToken("up_1-A") && !ResumableUploader.isToken("../x") && !ResumableUploader.isToken(""))
    }
}

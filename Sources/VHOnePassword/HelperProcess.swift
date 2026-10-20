import Darwin
import Foundation

/// What the helper's stdout produced.
enum HelperOutput: Sendable {
    /// One line without its newline. The receiver zeroes it.
    case line([UInt8])
    /// A line longer than the limit, discarded.
    case oversize
}

/// One running helper process: pipes, a reader thread splitting stdout into lines, and stderr kept as a short
/// in-memory tail (the helper's stderr is redacted diagnostics; it is not logged).
final class HelperProcess: @unchecked Sendable {
    let output: AsyncStream<HelperOutput>
    let processIdentifier: Int32

    private let process: Process
    private let stdinHandle: FileHandle
    private let stderrHandle: FileHandle
    private let lock = NSLock()
    private var inputClosed = false
    private var stderrTail: [String] = []
    private var stderrPartial = Data()

    init(executableURL: URL, environment: [String: String], maxLineBytes: Int) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = []
        process.environment = environment
        process.currentDirectoryURL = URL(filePath: NSTemporaryDirectory())
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Writing to a dead helper must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let (stream, continuation) = AsyncStream.makeStream(of: HelperOutput.self, bufferingPolicy: .unbounded)
        self.output = stream
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stderrHandle = stderr.fileHandleForReading

        try process.run() // Foundation closes the child's pipe ends in this process.
        processIdentifier = process.processIdentifier

        let readFD = stdout.fileHandleForReading.fileDescriptor
        let stdoutHandle = stdout.fileHandleForReading // keeps the descriptor open while the thread reads
        let thread = Thread {
            Self.readLines(fd: readFD, maxLineBytes: maxLineBytes, into: continuation)
            try? stdoutHandle.close()
        }
        thread.name = "vaulthalla-1password stdout"
        thread.start()

        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(data)
        }
    }

    deinit {
        terminate()
    }

    var isRunning: Bool { process.isRunning }

    /// The exit status once the process has exited.
    var exitStatus: Int32? {
        process.isRunning ? nil : process.terminationStatus
    }

    /// The last lines the helper wrote to stderr (redacted diagnostics).
    var diagnostics: [String] {
        lock.withLock { stderrTail }
    }

    /// Writes all of `bytes` to the helper's stdin.
    func write(_ bytes: UnsafeRawBufferPointer) throws(OnePasswordHelperError) {
        let closed = lock.withLock { inputClosed }
        if closed { throw .closed }
        let fd = stdinHandle.fileDescriptor
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw .exited(status: exitStatus)
            }
            offset += n
        }
    }

    /// Closes stdin; the helper exits when it reads EOF.
    func closeInput() {
        let first = lock.withLock {
            defer { inputClosed = true }
            return !inputClosed
        }
        if first { try? stdinHandle.close() }
    }

    /// Closes stdin and terminates the process if it is still running.
    func terminate() {
        closeInput()
        if process.isRunning { process.terminate() }
        stderrHandle.readabilityHandler = nil
    }

    private func appendStderr(_ data: Data) {
        lock.withLock {
            stderrPartial.append(data)
            while let newline = stderrPartial.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: stderrPartial[stderrPartial.startIndex..<newline], as: UTF8.self)
                stderrPartial.removeSubrange(stderrPartial.startIndex...newline)
                stderrTail.append(line)
                if stderrTail.count > 50 { stderrTail.removeFirst(stderrTail.count - 50) }
            }
            if stderrPartial.count > 4096 { stderrPartial.removeAll() }
        }
    }

    /// Blocking read loop on the reader thread. Buffers are zeroed as lines are handed on.
    private static func readLines(
        fd: Int32, maxLineBytes: Int, into continuation: AsyncStream<HelperOutput>.Continuation
    ) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var line = SecureByteBuffer(capacity: 4096)
        var discarding = false
        defer {
            chunk.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            continuation.finish()
        }

        func emitLine() {
            if discarding {
                continuation.yield(.oversize)
            } else {
                continuation.yield(.line(line.withUnsafeBytes { Array($0) }))
            }
            line.wipe()
            discarding = false
        }

        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            chunk.withUnsafeMutableBytes { raw in
                var start = 0
                for i in 0..<n where raw[i] == UInt8(ascii: "\n") {
                    if !discarding {
                        if line.count + (i - start) > maxLineBytes {
                            discarding = true
                            line.wipe()
                        } else {
                            line.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[start..<i]))
                        }
                    }
                    emitLine()
                    start = i + 1
                }
                if start < n, !discarding {
                    if line.count + (n - start) > maxLineBytes {
                        discarding = true
                        line.wipe()
                    } else {
                        line.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[start..<n]))
                    }
                }
                raw.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        if !line.isEmpty || discarding { emitLine() }
    }
}

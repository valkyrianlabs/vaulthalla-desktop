public import Foundation
import Synchronization

/// Runs an external program with an argument array, never through a shell, so nothing in a path or an argument is
/// ever interpreted. Every run has a deadline (then SIGTERM, and SIGKILL two seconds later), stdin is /dev/null so a
/// program can't wait for input, and output is capped and returned as data.
public struct ProcessRunner: Sendable {
    public struct Output: Sendable, Equatable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        public var timedOut: Bool

        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
        /// stdout then stderr, for matching a known message wherever the program put it.
        public var combinedText: String { stdoutText + "\n" + stderrText }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case couldNotStart(String)

        public var description: String {
            switch self {
            case .couldNotStart(let why): "couldn't be started: \(why)"
            }
        }
    }

    /// The most output kept per stream; the rest is read and dropped.
    public static let outputLimit = 1 << 20

    public init() {}

    public func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                    directory: URL? = nil, timeout: Duration) async throws(Failure) -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let run = Run()
        stdout.fileHandleForReading.readabilityHandler = { handle in run.append(handle.availableData, stderr: false) }
        stderr.fileHandleForReading.readabilityHandler = { handle in run.append(handle.availableData, stderr: true) }
        process.terminationHandler = { process in run.terminated(process.terminationStatus) }

        return try await withCheckedContinuation { (continuation: CheckedContinuation<Result<Output, Failure>, Never>) in
            run.onFinish { output in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: .success(output))
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                run.abandon()
                continuation.resume(returning: .failure(.couldNotStart(error.localizedDescription)))
                return
            }
            let pid = process.processIdentifier
            let queue = DispatchQueue.global(qos: .utility)
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                guard run.markTimedOut() else { return }
                kill(pid, SIGTERM)
                queue.asyncAfter(deadline: .now() + 2) {
                    if !run.hasTerminated { kill(pid, SIGKILL) }
                }
            }
            // A grandchild may keep a pipe open after the program exits: give the streams a moment, then finish.
            run.onTerminated {
                queue.asyncAfter(deadline: .now() + 2) { run.finishNow() }
            }
        }.get()
    }
}

/// One run's state, touched from the pipes' and the process's dispatch queues.
private final class Run: Sendable {
    private struct State {
        var stdout = Data()
        var stderr = Data()
        var stdoutClosed = false
        var stderrClosed = false
        var status: Int32?
        var timedOut = false
        var finished = false
        var finish: (@Sendable (ProcessRunner.Output) -> Void)?
        var terminated: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var hasTerminated: Bool { state.withLock { $0.status != nil } }

    func onFinish(_ body: @escaping @Sendable (ProcessRunner.Output) -> Void) {
        state.withLock { $0.finish = body }
    }

    func onTerminated(_ body: @escaping @Sendable () -> Void) {
        let already = state.withLock { state -> Bool in
            if state.status != nil { return true }
            state.terminated = body
            return false
        }
        if already { body() }
    }

    func append(_ data: Data, stderr: Bool) {
        state.withLock { state in
            if data.isEmpty {
                if stderr { state.stderrClosed = true } else { state.stdoutClosed = true }
                return
            }
            if stderr {
                if state.stderr.count < ProcessRunner.outputLimit {
                    state.stderr.append(data.prefix(ProcessRunner.outputLimit - state.stderr.count))
                }
            } else if state.stdout.count < ProcessRunner.outputLimit {
                state.stdout.append(data.prefix(ProcessRunner.outputLimit - state.stdout.count))
            }
        }
        complete(force: false)
    }

    func terminated(_ status: Int32) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            state.status = status
            defer { state.terminated = nil }
            return state.terminated
        }
        callback?()
        complete(force: false)
    }

    /// Returns false when the run already ended.
    func markTimedOut() -> Bool {
        state.withLock { state in
            guard state.status == nil else { return false }
            state.timedOut = true
            return true
        }
    }

    func finishNow() { complete(force: true) }

    func abandon() {
        state.withLock { $0.finished = true; $0.finish = nil }
    }

    private func complete(force: Bool) {
        let ready = state.withLock { state -> ((@Sendable (ProcessRunner.Output) -> Void), ProcessRunner.Output)? in
            guard !state.finished, let status = state.status, let finish = state.finish else { return nil }
            guard force || (state.stdoutClosed && state.stderrClosed) else { return nil }
            state.finished = true
            state.finish = nil
            return (finish, ProcessRunner.Output(status: status, stdout: state.stdout, stderr: state.stderr,
                                                 timedOut: state.timedOut))
        }
        if let (finish, output) = ready { finish(output) }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

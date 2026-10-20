public import Foundation

/// Key material in memory. It never prints, never encodes, and zeroes its buffer when the last reference goes away.
/// Use it for anything that must stay out of logs, caches and agent context (vault keys above all).
public final class SecretBytes: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let pointer: UnsafeMutableRawBufferPointer
    private let lock = NSLock()

    public init(_ bytes: some Collection<UInt8>) {
        pointer = .allocate(byteCount: bytes.count, alignment: 1)
        pointer.copyBytes(from: bytes)
    }

    /// Decodes base64 straight into a zeroing buffer. The intermediate `Data` is wiped before it is released.
    public convenience init?(base64: String) {
        guard var decoded = Data(base64Encoded: base64) else { return nil }
        self.init(decoded)
        decoded.resetBytes(in: 0..<decoded.count)
    }

    deinit {
        pointer.initializeMemory(as: UInt8.self, repeating: 0)
        pointer.deallocate()
    }

    public var count: Int { pointer.count }

    /// Gives the bytes to `body` without copying them out. Don't let them escape the closure.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(UnsafeRawBufferPointer(pointer))
    }

    public var description: String { "SecretBytes(\(count) bytes, redacted)" }
    public var debugDescription: String { description }
}

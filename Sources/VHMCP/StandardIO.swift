public import Foundation

/// The stdio transport of MCP: newline-delimited JSON-RPC messages.
public enum StandardIO {
    /// Lines of stdin as raw bytes, split on `\n` only (a JSON string may hold U+2028, which Foundation's line
    /// sequences would split on). A trailing `\r` is dropped. Ends at end of file.
    public static func lines(from handle: FileHandle = .standardInput) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let fd = handle.fileDescriptor
            let thread = Thread {
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    pending.append(contentsOf: buffer[0..<count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        var line = pending[pending.startIndex..<newline]
                        if line.last == 0x0D { line = line.dropLast() }
                        continuation.yield(Data(line))
                        pending = Data(pending[pending.index(after: newline)...])
                    }
                }
                if !pending.isEmpty { continuation.yield(pending) }
                continuation.finish()
            }
            thread.name = "vaulthalla-mcp stdin"
            thread.start()
        }
    }

    /// Writes protocol messages to stdout, one at a time. A closed stdout (the client went away) is ignored; the
    /// bridge ends when stdin does.
    public actor Writer {
        private let handle: FileHandle

        public init(handle: FileHandle = .standardOutput) {
            self.handle = handle
        }

        public func write(_ data: Data) {
            try? handle.write(contentsOf: data)
        }
    }
}

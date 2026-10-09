#if os(Windows)
import Foundation
import Logging
import MCP

/// Stdio-Transport für Windows: das SDK bringt `StdioTransport` nur für Darwin, Glibc und Musl mit.
/// Nachrichten sind JSON-Zeilen auf stdin und stdout, wie in der MCP-Spezifikation.
actor LineStdioTransport: Transport {
    nonisolated let logger = Logger(label: "kastellan.stdio")
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var started = false

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        guard !started else { return }
        started = true
        let continuation = self.continuation
        Thread.detachNewThread {
            var buffer = Data()
            let input = FileHandle.standardInput
            while true {
                let chunk = input.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    var line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if line.last == 0x0D { line = line.dropLast() }
                    if !line.isEmpty { continuation.yield(Data(line)) }
                }
            }
            continuation.finish()
        }
    }

    func disconnect() async { continuation.finish() }

    func send(_ data: Data) async throws {
        var out = data
        out.append(0x0A)
        FileHandle.standardOutput.write(out)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }
}
#endif

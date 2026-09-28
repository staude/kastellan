import Foundation

/// Startet ein Kommandozeilenwerkzeug (bw, op) mit Umgebung und stdin, liefert stdout, stderr, Exit-Code.
public struct CLIResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

public protocol CLIRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String], stdin: String?) async throws -> CLIResult
}

public struct ProcessCLIRunner: CLIRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], environment: [String: String], stdin: String?) async throws -> CLIResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
            for (k, v) in environment { env[k] = v }
            p.environment = env
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out; p.standardError = err; p.standardInput = inp
            do { try p.run() } catch { cont.resume(throwing: KastellanError.internal("\(executable) starten: \(error.localizedDescription)")); return }
            if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
            try? inp.fileHandleForWriting.close()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: CLIResult(status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                                             stderr: String(decoding: errData, as: UTF8.self)))
        }
    }

    /// Findet ein Werkzeug in den üblichen Pfaden.
    public static func locate(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(NSHomeDirectory())/.local/bin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

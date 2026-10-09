import Foundation

/// Absturzerkennung ohne Signal-Handler: beim Start liegt ein Marker des vorigen Laufs, wenn der Prozess
/// nicht sauber beendet wurde. Dann wird der jüngste Absturzbericht von macOS gelesen und gemeldet.
public struct CrashReporter: Sendable {
    public let component: String
    private let marker: URL
    private let reportsDirectory: URL

    public init(component: String,
                reportsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")) {
        self.component = component
        self.marker = AppPaths.home.appendingPathComponent("running-\(component).marker")
        self.reportsDirectory = reportsDirectory
    }

    /// Beim Start aufrufen. Meldet einen vorigen Absturz und setzt den Marker für diesen Lauf.
    public func checkAndArm(processName: String) async {
        if let previousStart = markerDate() {
            if let report = latestReport(for: processName, since: previousStart) {
                await Telemetry.shared.captureCrash(
                    type: report.type, value: report.value, frames: report.frames, occurredAt: report.occurredAt,
                    tags: ["crash": "true", "signal": report.signal],
                    extra: ["report": report.fileName, "version": report.version, "termination": report.termination],
                    device: report.device)
            }
            // Ohne Absturzbericht keine Meldung: SIGTERM durch Installer oder MCP-Client ist kein Fehler.
        }
        arm()
    }

    /// SIGTERM, SIGINT und SIGHUP als sauberes Ende behandeln: Marker entfernen, dann `onExit`.
    /// Ohne das würde jedes Beenden durch Installer oder MCP-Client wie ein Absturz aussehen.
    public func handleTerminationSignals(onExit: @escaping @Sendable () -> Void) {
        #if os(Windows)
        // Unter Windows gibt es keine Signalquellen in Dispatch; der Marker bleibt bei hartem Beenden liegen.
        return
        #else
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            let marker = self.marker
            source.setEventHandler {
                try? FileManager.default.removeItem(at: marker)
                onExit()
            }
            source.resume()
            Self.retainedSources.append(source)
        }
        #endif
    }

    #if !os(Windows)
    nonisolated(unsafe) private static var retainedSources: [DispatchSourceSignal] = []
    #endif

    /// Diagnose: jüngsten Bericht seit `since` lesen und melden, ohne Marker zu verändern.
    public func report(latestFor processName: String, since: Date) async -> String {
        guard let report = latestReport(for: processName, since: since) else {
            return "kein Absturzbericht für \(processName) seit \(since.formatted(.iso8601)) unter \(reportsDirectory.path)"
        }
        await Telemetry.shared.captureCrash(type: report.type, value: report.value, frames: report.frames, occurredAt: report.occurredAt,
                                            tags: ["crash": "true", "signal": report.signal, "diagnose": "true"],
                                            extra: ["report": report.fileName, "version": report.version, "termination": report.termination],
                                            device: report.device)
        await Telemetry.shared.flush(timeout: 10)
        let status = await Telemetry.shared.lastStatus
        let outbox = await Telemetry.shared.outboxCount()
        return "\(report.fileName): \(report.summary), \(report.frames.count) Frames, Zeit \(report.occurredAt.map { $0.formatted(.iso8601) } ?? "?"), gesendet: \(status), Postausgang: \(outbox)"
    }

    /// Bei sauberem Ende aufrufen.
    public func disarm() {
        try? FileManager.default.removeItem(at: marker)
    }

    // MARK: - Intern

    private func arm() {
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: marker, options: .atomic)
    }

    private func markerDate() -> Date? {
        guard let data = try? Data(contentsOf: marker) else { return nil }
        return ISO8601DateFormatter().date(from: String(decoding: data, as: UTF8.self)) ?? Date.distantPast
    }

    struct Report {
        var fileName: String
        /// Etwa `EXC_BREAKPOINT (SIGTRAP)` oder `Fatal error`.
        var type: String
        /// Fehlertext, etwa die Swift-Meldung „Unexpectedly found nil …“, sonst Signal und Terminierung.
        var value: String
        var signal: String
        var termination: String
        var frames: [Telemetry.Frame]
        var version: String
        var occurredAt: Date?
        var device: [String: String]
        var summary: String { "\(type): \(value)" }
    }

    /// Jüngster `.ips`-Bericht des Prozesses, der nach dem Marker entstanden ist.
    func latestReport(for processName: String, since: Date) -> Report? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: reportsDirectory.path) else { return nil }
        let candidates = names.filter { $0.hasPrefix(processName + "-") && $0.hasSuffix(".ips") }
            .map { reportsDirectory.appendingPathComponent($0) }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
                return (url, date)
            }
            .filter { $0.1 >= since.addingTimeInterval(-5) }
            .sorted { $0.1 > $1.1 }
        guard let (url, _) = candidates.first, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.parse(text, fileName: url.lastPathComponent)
    }

    /// Liest aus dem zweizeiligen JSON-Format der .ips-Datei Signal, Fehlertext (Swift-Meldung aus `asi`),
    /// Version, Gerät, Zeitpunkt und die Frames des auslösenden Threads.
    static func parse(_ text: String, fileName: String) -> Report {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        var version = "?"
        var occurredAt: Date?
        if lines.count > 0, let header = try? JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any] {
            version = (header["app_version"] as? String) ?? "?"
            if let stamp = header["timestamp"] as? String {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
                occurredAt = f.date(from: stamp)
            }
        }
        var type = "Crash"
        var signal = "?"
        var termination = ""
        var value = ""
        var frames: [Telemetry.Frame] = []
        var device: [String: String] = [:]
        if lines.count > 1, let body = try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any] {
            if let exc = body["exception"] as? [String: Any] {
                signal = (exc["signal"] as? String) ?? "?"
                let t = (exc["type"] as? String) ?? "Crash"
                type = signal == "?" ? t : "\(t) (\(signal))"
            }
            if let term = body["termination"] as? [String: Any], let indicator = term["indicator"] as? String {
                termination = indicator
            }
            // Swift-Fehlertext, etwa "Fatal error: Unexpectedly found nil ..."
            if let asi = body["asi"] as? [String: Any] {
                let texts = asi.values.compactMap { $0 as? [String] }.flatMap { $0 }
                if let first = texts.first { value = first }
            }
            if value.isEmpty { value = termination.isEmpty ? signal : termination }
            if let model = body["modelCode"] as? String { device["model"] = model }
            if let os = body["osVersion"] as? [String: Any], let train = os["train"] as? String { device["os"] = train }
            let images = body["usedImages"] as? [[String: Any]] ?? []
            if let threads = body["threads"] as? [[String: Any]],
               let crashed = threads.first(where: { ($0["triggered"] as? Bool) == true }) ?? threads.first,
               let list = crashed["frames"] as? [[String: Any]] {
                // Bericht listet den auslösenden Frame zuerst, Sentry will ihn zuletzt.
                for f in list.prefix(30).reversed() {
                    let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
                    let symbol = (f["symbol"] as? String) ?? "+\(f["imageOffset"] ?? 0)"
                    frames.append(Telemetry.Frame(module: image, function: symbol, file: f["sourceFile"] as? String,
                                                  line: f["sourceLine"] as? Int, inApp: image.hasPrefix("Kastellan") || image.hasPrefix("kastellan")))
                }
            }
        }
        return Report(fileName: fileName, type: type, value: value, signal: signal, termination: termination,
                      frames: frames, version: version, occurredAt: occurredAt, device: device)
    }
}
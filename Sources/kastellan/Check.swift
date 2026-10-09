import Foundation
import KastellanCore

// Hintergrundprüfung ohne Oberfläche, wie bei TorroMail: ein systemd-User-Timer startet
// `kastellan check` alle zwei Minuten. Jeder Lauf meldet neue Freigaben (nur lokale Dateien, billig);
// die Verbindungen prüft er höchstens einmal je Stunde, damit die Rate-Limits der Provider geschont
// werden. Meldungen gehen per `notify-send` an den Desktop, auf macOS per `osascript`.

/// Was der letzte Lauf schon gemeldet hat: Freigaben und Zustand je Verbindung.
struct CheckState: Codable {
    var notifiedPending: [String] = []
    var lastHealthRun: Date?
    var healthy: [String: Bool] = [:]

    static var file: URL { AppPaths.home.appendingPathComponent("check-state.json") }

    static func load() -> CheckState {
        guard let data = try? Data(contentsOf: file), let state = try? JSONCoding.decoder.decode(CheckState.self, from: data) else { return CheckState() }
        return state
    }

    func save() {
        if let data = try? JSONCoding.encoder.encode(self) { try? data.write(to: Self.file, options: .atomic) }
    }
}

enum Check {
    typealias Notify = (String, String) -> Void

    /// Ein Lauf. `healthEvery` in Sekunden; `force` prüft die Verbindungen sofort.
    @discardableResult
    static func run(healthEvery: TimeInterval = 3600, force: Bool = false, notify: Notify = Notifier.send) async throws -> [String] {
        let runtime = try Runtime.standard(registry: BuiltinAdapters.registry)
        var state = CheckState.load()
        var report: [String] = []

        // Freigaben: jede offene genau einmal melden.
        let open = try await runtime.pending.list().filter { $0.status == .prepared }
        let fresh = open.filter { !state.notifiedPending.contains($0.id) }
        for action in fresh {
            notify("Kastellan: Freigabe nötig", "\(Line.clean(action.preview)) (\(Line.clean(action.client)))")
            report.append("Freigabe gemeldet: \(Line.clean(action.preview))")
        }
        state.notifiedPending = open.map(\.id)

        // Verbindungen: höchstens alle `healthEvery` Sekunden, Meldung nur bei Wechsel.
        let due = force || state.lastHealthRun.map { Date().timeIntervalSince($0) >= healthEvery } ?? true
        if due {
            for connection in try await runtime.connections.list() {
                let status: HealthStatus
                do {
                    let adapter = try runtime.registry.adapter(for: connection, secrets: runtime.secrets)
                    status = await adapter.healthCheck()
                } catch {
                    status = HealthStatus(connectionID: connection.id, ok: false, message: error.localizedDescription)
                }
                try? runtime.health.append(status)
                let before = state.healthy[connection.id]
                if before != status.ok, before != nil || !status.ok {
                    notify(Line.clean(connection.label), status.ok ? "Wieder erreichbar." : "Kastellan erreicht die Verbindung nicht mehr: \(Line.clean(status.message))")
                }
                state.healthy[connection.id] = status.ok
                report.append(Line.clean("\(connection.label): \(status.ok ? "ok" : "Fehler") \(status.message)"))
            }
            state.lastHealthRun = Date()
        }
        state.save()
        return report
    }
}

/// Desktop-Mitteilungen. Fehlt das Werkzeug, bleibt es still; der Lauf soll daran nicht scheitern.
enum Notifier {
    static func send(_ title: String, _ body: String) {
        #if os(Linux)
        launch("/usr/bin/env", ["notify-send", "--app-name", "Kastellan", "--icon", "dialog-password", title, body])
        #elseif os(macOS)
        let script = "display notification \(quoted(body)) with title \(quoted(title))"
        launch("/usr/bin/osascript", ["-e", script])
        #else
        // Windows: Mitteilungen folgen später, wie bei TorroMail.
        _ = (title, body)
        #endif
    }

    /// AppleScript-Text sicher in Anführungszeichen.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func launch(_ executable: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch {}
    }
}

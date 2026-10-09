import Foundation
import KastellanCore

/// Hintergrundprüfung als systemd-User-Timer (Linux). Kein eigener Dienst, der laufen muss: der Timer
/// startet `kastellan check` alle zwei Minuten, ausgeschaltet läuft gar nichts. Auf macOS übernimmt das
/// die App, unter Windows gibt es das noch nicht.
enum AutoCheck {
    static let service = "kastellan-check.service"
    static let timer = "kastellan-check.timer"

    static var supported: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }

    /// `$XDG_CONFIG_HOME/systemd/user`, sonst `~/.config/systemd/user`.
    static var unitDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("systemd/user", isDirectory: true)
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: unitDirectory.appendingPathComponent(timer).path) }

    static var program: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }

    static func serviceUnit(program: URL, home: String?) -> String {
        var unit = "[Unit]\nDescription=Kastellan: Freigaben melden und Verbindungen prüfen\n\n[Service]\nType=oneshot\n"
        // Abweichendes Datenverzeichnis mitnehmen, sonst prüft der Timer andere Daten als die Oberfläche.
        if let home, !home.isEmpty { unit += "Environment=\"KASTELLAN_HOME=\(home)\"\n" }
        unit += "ExecStart=\"\(program.path)\" check\n"
        return unit
    }

    static let timerUnit = """
    [Unit]
    Description=Kastellan: regelmäßig prüfen

    [Timer]
    OnStartupSec=1min
    OnUnitActiveSec=2min

    [Install]
    WantedBy=timers.target

    """

    static func enable() throws -> String {
        guard supported else { throw KastellanError.unsupported("Die Hintergrundprüfung gibt es bisher nur unter Linux (systemd). Auf macOS meldet die App Freigaben selbst.") }
        try FileManager.default.createDirectory(at: unitDirectory, withIntermediateDirectories: true)
        let home = ProcessInfo.processInfo.environment["KASTELLAN_HOME"]
        try serviceUnit(program: program, home: home).write(to: unitDirectory.appendingPathComponent(service), atomically: true, encoding: .utf8)
        try timerUnit.write(to: unitDirectory.appendingPathComponent(timer), atomically: true, encoding: .utf8)
        do {
            try systemctl(["daemon-reload"])
            try systemctl(["enable", "--now", timer])
        } catch {
            // Nichts halb eingerichtet liegen lassen.
            for name in [timer, service] { try? FileManager.default.removeItem(at: unitDirectory.appendingPathComponent(name)) }
            throw KastellanError.unsupported("Hintergrundprüfung braucht systemd mit Benutzersitzung (systemctl --user). \(error.localizedDescription)")
        }
        return "Hintergrundprüfung an: alle 2 Minuten Freigaben, stündlich die Verbindungen (\(unitDirectory.path))."
    }

    static func disable() throws -> String {
        guard supported else { throw KastellanError.unsupported("Die Hintergrundprüfung gibt es bisher nur unter Linux (systemd).") }
        try? systemctl(["disable", "--now", timer])
        for name in [timer, service] { try? FileManager.default.removeItem(at: unitDirectory.appendingPathComponent(name)) }
        try? systemctl(["daemon-reload"])
        return "Hintergrundprüfung aus."
    }

    static func status() -> String {
        guard supported else { return "Hintergrundprüfung: nicht verfügbar auf \(PlatformInfo.name)" }
        let state = CheckState.load()
        var text = "Hintergrundprüfung: \(isEnabled ? "an" : "aus")"
        if let last = state.lastHealthRun { text += ", Verbindungen zuletzt geprüft \(last.short)" }
        return text
    }

    private static func systemctl(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["systemctl", "--user"] + arguments
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw KastellanError.internal("systemctl --user \(arguments.joined(separator: " ")): \(msg.isEmpty ? "Status \(p.terminationStatus)" : msg)")
        }
    }
}

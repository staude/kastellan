import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Ablageorte von Kastellan. App und kastellan-mcp teilen sich dieses Verzeichnis.
/// `KASTELLAN_HOME` überschreibt den Ordner (Tests, CI, mehrere Instanzen).
public enum AppPaths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["KASTELLAN_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let env = ProcessInfo.processInfo.environment
        #if os(macOS)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Kastellan", isDirectory: true)
        #elseif os(Windows)
        // %LOCALAPPDATA%\Kastellan, wie TorroMail.
        let base = env["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return base.appendingPathComponent("Kastellan", isDirectory: true)
        #else
        // $XDG_STATE_HOME/kastellan, Standard ~/.local/state/kastellan, wie TorroMail.
        let base = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state", isDirectory: true)
        return base.appendingPathComponent("kastellan", isDirectory: true)
        #endif
    }

    public static var connectionsFile: URL { home.appendingPathComponent("connections.json") }
    public static var tokensFile: URL { home.appendingPathComponent("tokens.json") }
    public static var profilesFile: URL { home.appendingPathComponent("profiles.json") }
    public static var assignmentsFile: URL { home.appendingPathComponent("assignments.json") }
    public static var credentialsFile: URL { home.appendingPathComponent("credentials.json") }
    public static var handoffDirectory: URL { home.appendingPathComponent("credential-handoff", isDirectory: true) }
    public static var policiesDirectory: URL { home.appendingPathComponent("policies", isDirectory: true) }
    public static var pendingDirectory: URL { home.appendingPathComponent("pending", isDirectory: true) }
    public static var auditFile: URL { home.appendingPathComponent("audit.jsonl") }
    public static var healthFile: URL { home.appendingPathComponent("health.jsonl") }

    /// Legt das Home-Verzeichnis mit Unterordnern an (0700) und migriert alte Dateinamen.
    public static func ensureDirectories() throws {
        for dir in [home, policiesDirectory, pendingDirectory] {
            #if os(Windows)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #else
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            #endif
        }
        // Bis 0.1: contexts.json. Profile hießen Kontexte.
        let legacy = home.appendingPathComponent("contexts.json")
        if !FileManager.default.fileExists(atPath: profilesFile.path), FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.moveItem(at: legacy, to: profilesFile)
        }
    }
}

/// Atomares Schreiben: erst in eine temporäre Datei im selben Ordner, dann Rename.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: [.atomic])
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        #endif
        try replace(url, with: tmp)
    }

    /// Ersetzt `url` atomar durch `tmp`. Foundation auf Linux und Windows kann `replaceItemAt` nur bei
    /// vorhandenem Ziel; `rename` bzw. `MoveFileExW` ersetzen dort in einem Schritt.
    private static func replace(_ url: URL, with tmp: URL) throws {
        #if os(macOS)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        #elseif os(Windows)
        let ok = tmp.path.withCString(encodedAs: UTF16.self) { from in
            url.path.withCString(encodedAs: UTF16.self) { to in MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) }
        }
        guard ok else { throw KastellanError.internal("Datei ersetzen fehlgeschlagen: \(url.path) (\(GetLastError()))") }
        #else
        guard rename(tmp.path, url.path) == 0 else {
            throw KastellanError.internal("Datei ersetzen fehlgeschlagen: \(url.path) (errno \(errno))")
        }
        #endif
    }
}

public enum JSONCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

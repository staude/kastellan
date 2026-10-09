import Foundation

/// Schreibt den Kastellan-Eintrag in die MCP-Konfiguration von Claude Code oder Claude Desktop,
/// nach dem Muster von TorroMail: Binary im App-Bundle, Token in `env`.
public struct MCPConfigWriter: Sendable {
    public enum Target: String, CaseIterable, Sendable {
        case claudeCode = "claude-code"
        case claudeDesktop = "claude-desktop"

        public var displayName: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .claudeDesktop: "Claude Desktop"
            }
        }

        public var defaultFile: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeCode:
                return home.appendingPathComponent(".claude.json")
            case .claudeDesktop:
                #if os(Windows)
                let appData = ProcessInfo.processInfo.environment["APPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? home.appendingPathComponent("AppData/Roaming", isDirectory: true)
                return appData.appendingPathComponent("Claude/claude_desktop_config.json")
                #elseif os(macOS)
                return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
                #else
                // Kein offizielles Claude Desktop für Linux; inoffizielle Builds nutzen ~/.config/Claude.
                return home.appendingPathComponent(".config/Claude/claude_desktop_config.json")
                #endif
            }
        }
    }

    /// Servername je Profil: `kastellan-privat`, `kastellan-beruflich`.
    public static func serverName(profile: KastellanProfile) -> String { "kastellan-\(profile.slug)" }
    public static let tokenVariable = "KASTELLAN_TOKEN"

    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Pfad des MCP-Binaries neben dem laufenden Programm (App oder kastellan-mcp selbst).
    public static func bundledExecutable() -> URL {
        let own = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        #if os(Windows)
        let name = "kastellan-mcp.exe"
        #else
        let name = "kastellan-mcp"
        #endif
        if own.lastPathComponent.lowercased() == name { return own }
        return own.deletingLastPathComponent().appendingPathComponent(name)
    }

    public func entry(token: String, target: Target) -> [String: Any] {
        var e: [String: Any] = [
            "command": executable.path,
            "env": [Self.tokenVariable: token],
        ]
        if target == .claudeCode {
            e["type"] = "stdio"
            e["args"] = [String]()
        }
        return e
    }

    /// JSON-Schnipsel zum Kopieren, mit Servernamen als Schlüssel.
    public func snippet(token: String, target: Target, profile: KastellanProfile) -> String {
        let obj: [String: Any] = [Self.serverName(profile: profile): entry(token: token, target: target)]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Fügt den Eintrag unter `mcpServers.kastellan-<profil>` ein oder ersetzt ihn. Andere Schlüssel bleiben
    /// unangetastet, vorher wird eine Sicherungskopie `<datei>.bak-<zeit>` geschrieben.
    @discardableResult
    public func install(token: String, target: Target, profile: KastellanProfile, into file: URL? = nil) throws -> URL {
        let url = file ?? target.defaultFile
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw KastellanError.invalidArgument("\(url.path) enthält kein JSON-Objekt")
            }
            root = parsed
            let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).bak-\(stamp)")
            try data.write(to: backup, options: [.atomic])
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.serverName(profile: profile)] = entry(token: token, target: target)
        root["mcpServers"] = servers
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try AtomicFile.write(out, to: url)
        return url
    }

    /// Entfernt den Eintrag wieder.
    public func uninstall(target: Target, profile: KastellanProfile, from file: URL? = nil) throws {
        let url = file ?? target.defaultFile
        let name = Self.serverName(profile: profile)
        guard let data = try? Data(contentsOf: url),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any],
              servers[name] != nil else { return }
        servers.removeValue(forKey: name)
        root["mcpServers"] = servers
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try AtomicFile.write(out, to: url)
    }

    public func isInstalled(target: Target, profile: KastellanProfile, in file: URL? = nil) -> Bool {
        let url = file ?? target.defaultFile
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return servers[Self.serverName(profile: profile)] != nil
    }
}

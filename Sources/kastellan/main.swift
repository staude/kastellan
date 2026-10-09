import Foundation
import KastellanCore

// kastellan: Terminal-Oberfläche für Kastellan auf macOS, Linux und Windows.
//   kastellan             Oberfläche starten
//   kastellan status      Zustand ohne Oberfläche ausgeben
//   kastellan --version

let arguments = Array(CommandLine.arguments.dropFirst())

func printStatus() async throws {
    let runtime = try Runtime.standard(registry: BuiltinAdapters.registry)
    print("Kastellan \(KastellanCore.version) auf \(PlatformInfo.name)")
    print("Daten: \(AppPaths.home.path)")
    print("Zugangsdaten: \((runtime.secrets as? any ManagedSecretStore)?.displayName ?? "–")")
    print("MCP-Programm: \(MCPConfigWriter.bundledExecutable().path)")
    let health = (try? runtime.health.latest()) ?? [:]
    for profile in try await runtime.profiles.list() {
        print("\nProfil \(profile.name)")
        for c in try await runtime.connections.list() where c.profileID == profile.id {
            let h = health[c.id]
            print("  \(h.map { $0.ok ? "ok    " : "FEHLER" } ?? "?     ") \(c.label) [\(c.provider)] \(h?.message ?? "")")
        }
        for t in try await runtime.tokens.list() where t.profileID == profile.id && !t.isRevoked {
            print("  Client \(t.client)")
        }
    }
    let open = try await runtime.pending.list()
    print("\nOffene Freigaben: \(open.count)")
    for a in open { print("  \(a.preview) (\(a.client))") }
}

switch arguments.first {
case "--version", "-v":
    print("kastellan \(KastellanCore.version) (\(PlatformInfo.name))")
case "status":
    do { try await printStatus() } catch {
        FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
case "--help", "-h", "help":
    print("""
    kastellan \(KastellanCore.version): Terminal-Oberfläche für Kastellan.

      kastellan            Oberfläche starten (Verbindungen, Rechte, MCP-Clients, Freigaben, Protokoll)
      kastellan status     Zustand ohne Oberfläche ausgeben
      kastellan --version

    Daten liegen in \(AppPaths.home.path) (KASTELLAN_HOME überschreibt den Ort).
    Der MCP-Server ist das Programm kastellan-mcp im selben Ordner.
    """)
case nil:
    guard TerminalCheck.stdinIsTerminal else {
        FileHandle.standardError.write(Data("kastellan braucht ein Terminal. Für Skripte: kastellan status\n".utf8))
        exit(1)
    }
    do {
        let tui = try TUI()
        await tui.run()
    } catch {
        FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
default:
    FileHandle.standardError.write(Data("Unbekannter Befehl \(arguments[0]). kastellan --help zeigt die Befehle.\n".utf8))
    exit(1)
}

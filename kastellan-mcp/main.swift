import Foundation
import KastellanCore
import MCP

// kastellan-mcp: stdio-MCP-Server, eingebettet in Kastellan.app/Contents/MacOS, auf Linux und Windows
// als eigenes Programm neben `kastellan`.
//
// Ohne Argumente startet der Server. Das Client-Token kommt aus KASTELLAN_TOKEN und wird gegen
// tokens.json im Kastellan-Home geprüft. Ohne gültiges Token gibt es nur kastellan_version.
//
// Unterbefehle für Setup ohne App (gleicher Core wie die App):
//   kastellan-mcp profile list
//   kastellan-mcp token create <client> --profile <profil>
//   kastellan-mcp token list
//   kastellan-mcp token revoke <id>
//   kastellan-mcp install-config --client <name> --profile <profil> --target claude-code|claude-desktop [--file <pfad>]
//   kastellan-mcp doctor
//   kastellan-mcp --version

let arguments = Array(CommandLine.arguments.dropFirst())

enum ContextStoreCompat {
    static func profiles() async throws -> [KastellanProfile] { try await ProfileStore().list() }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func optionValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch arguments.first {
case "--version", "-v":
    print("kastellan-mcp \(KastellanCore.version)")
    exit(0)

case "doctor":
    // Diagnose: Profile, Verbindungen, Schlüsselbund-Zugriff (nur Schlüsselnamen, keine Werte).
    // `doctor --crash` liest den jüngsten Absturzbericht der App und sendet ihn an die Telemetrie.
    try AppPaths.ensureDirectories()
    if arguments.contains("--health") {
        // Health-Check aller Verbindungen ausführen und ins Health-Log schreiben.
        let runtime = try Runtime.standard(registry: BuiltinAdapters.registry)
        for c in try await runtime.connections.list() {
            do {
                let adapter = try runtime.registry.adapter(for: c, secrets: runtime.secrets)
                let status = await adapter.healthCheck()
                try runtime.health.append(status)
                print("\(c.label) [\(c.provider)]: \(status.ok ? "ok" : "FEHLER") \(status.message)")
            } catch {
                print("\(c.label) [\(c.provider)]: FEHLER \(error.localizedDescription)")
            }
        }
        exit(0)
    }
    if arguments.contains("--crash") {
        await Telemetry.shared.configure(component: "app")
        print("Telemetrie aktiv: \(await Telemetry.shared.isEnabled), Ziel \(await Telemetry.shared.storeURLDescription)")
        let since = Date(timeIntervalSinceNow: -7 * 86400)
        print(await CrashReporter(component: "app").report(latestFor: "Kastellan", since: since))
        exit(0)
    }
    print("kastellan-mcp \(KastellanCore.version), Home \(AppPaths.home.path)")
    print("Binary \(Bundle.main.executableURL?.path ?? "?")")
    print("Plattform \(PlatformInfo.name)")
    let store = makePlatformSecretStore()
    #if canImport(Security)
    if let keychain = store as? KeychainSecretStore {
        print("Vertraute Programme für den Schlüsselbund: \(keychain.trustedPaths.joined(separator: ", "))")
    }
    #endif
    print("Secrets: \(store.displayName)")
    for c in try await ProfileStore().list() { print("Profil \(c.slug) (\(c.name))") }
    for c in try await ConnectionStore().list() {
        let keys = (try? store.keys(connectionID: c.id)) ?? []
        var readable: [String] = []
        for k in keys where (try? await store.secret(connectionID: c.id, key: k)) != nil { readable.append(k) }
        print("Verbindung \(c.label) [\(c.provider)] Secrets: \(keys.joined(separator: ", ")) lesbar: \(readable.joined(separator: ", "))")
    }
    for t in try await TokenStore().list() where !t.isRevoked { print("Token \(t.client) (\(t.id))") }
    let credentialSettings = CredentialSettingsStore()
    for c in try await ContextStoreCompat.profiles() {
        let cfg = (try? await credentialSettings.config(profileID: c.id)) ?? CredentialDeliveryConfig()
        print("Ablage \(c.name): \(cfg.kind.displayName)\(cfg.target.description.isEmpty ? "" : ", \(cfg.target.description)")")
    }
    let waiting = (try? await CredentialHandoffStore(secrets: makePlatformSecretStore()).list()) ?? []
    print("Wartende Übergaben: \(waiting.count)")
    exit(0)

case "profile", "context":
    try AppPaths.ensureDirectories()
    for c in try await ProfileStore().list() {
        print("\(c.slug)  \(c.name)  (\(c.id))")
    }
    exit(0)

case "token":
    try AppPaths.ensureDirectories()
    let store = TokenStore()
    let profiles = ProfileStore()
    switch arguments.dropFirst().first {
    case "create":
        guard let client = arguments.dropFirst(2).first, !client.hasPrefix("--") else { fail("token create <client> --profile <profil>") }
        guard let slug = (optionValue("--profile", in: arguments) ?? optionValue("--context", in: arguments)), let ctx = try await profiles.find(slug: slug) else {
            fail("--profile <profil> fehlt oder unbekannt. Vorhanden: \(try await profiles.list().map(\.slug).joined(separator: ", "))")
        }
        let issued = try await store.issue(client: client, profileID: ctx.id)
        print(issued.token)
        FileHandle.standardError.write(Data("Token für \(client) im Profil \(ctx.name) angelegt (id \(issued.record.id)). Es wird nicht erneut angezeigt.\n".utf8))
    case "list":
        let byID = Dictionary(uniqueKeysWithValues: try await profiles.list().map { ($0.id, $0.name) })
        for t in try await store.list() {
            let state = t.isRevoked ? "widerrufen" : "aktiv"
            print("\(t.id)  \(byID[t.profileID] ?? t.profileID)/\(t.client)  \(state)  angelegt \(t.createdAt.formatted(.iso8601))")
        }
    case "revoke":
        guard let id = arguments.dropFirst(2).first else { fail("token revoke <id>") }
        try await store.revoke(id: id)
        print("Token \(id) widerrufen.")
    default:
        fail("token create <client> | token list | token revoke <id>")
    }
    exit(0)

case "install-config":
    try AppPaths.ensureDirectories()
    guard let client = optionValue("--client", in: arguments) else { fail("--client <name> fehlt") }
    guard let targetRaw = optionValue("--target", in: arguments),
          let target = MCPConfigWriter.Target(rawValue: targetRaw) else {
        fail("--target claude-code | claude-desktop")
    }
    let file = optionValue("--file", in: arguments).map { URL(fileURLWithPath: $0) }
    guard let slug = (optionValue("--profile", in: arguments) ?? optionValue("--context", in: arguments)), let ctx = try await ProfileStore().find(slug: slug) else {
        fail("--profile <profil> fehlt oder unbekannt")
    }
    let issued = try await TokenStore().issue(client: client, profileID: ctx.id)
    let writer = MCPConfigWriter(executable: MCPConfigWriter.bundledExecutable())
    let written = try writer.install(token: issued.token, target: target, profile: ctx, into: file)
    print("Eintrag \"\(MCPConfigWriter.serverName(profile: ctx))\" in \(written.path) geschrieben, Token für \(client) angelegt.")
    print("Claude neu starten oder MCP-Verbindungen neu laden.")
    exit(0)

case nil:
    if TerminalCheck.stdinIsTerminal {
        // Interaktiv im Terminal gestartet: der Server wartet auf JSON-RPC über stdin, das wirkt wie „nichts passiert“.
        print("""
        kastellan-mcp \(KastellanCore.version): MCP-Server für Claude, spricht JSON-RPC über stdin/stdout.
        Ohne Argumente wartet er auf einen MCP-Client (Claude Code, Claude Desktop) und ist im Terminal stumm.

        Befehle:
          kastellan-mcp doctor                       Zustand: Profile, Verbindungen, Schlüsselbund-Zugriff
          kastellan-mcp profile list
          kastellan-mcp token create <client> --profile <profil>
          kastellan-mcp token list | token revoke <id>
          kastellan-mcp install-config --client <name> --profile <profil> --target claude-code|claude-desktop
          kastellan-mcp --version

        Einrichtung läuft über die App Kastellan oder im Terminal über `kastellan` (Terminal-Oberfläche).
        """)
        exit(0)
    }

default:
    fail("Unbekannter Befehl: \(arguments[0])")
}

// MARK: - Server

try AppPaths.ensureDirectories()
await Telemetry.shared.configure(component: "mcp")
let crashReporter = CrashReporter(component: "mcp")
await crashReporter.checkAndArm(processName: "kastellan-mcp")
crashReporter.handleTerminationSignals { exit(0) }

let tokenValue = ProcessInfo.processInfo.environment[MCPConfigWriter.tokenVariable]
let clientToken: ClientToken? = try await {
    guard let tokenValue, !tokenValue.isEmpty else { return nil }
    return try await TokenStore().verify(tokenValue)
}()
let clientProfile: KastellanProfile? = try await {
    guard let clientToken else { return nil }
    return try await ProfileStore().get(id: clientToken.profileID)
}()

let runtime = try Runtime.standard(registry: BuiltinAdapters.registry)
let toolServer = ToolServer(service: ActionService(runtime: runtime), token: clientToken, profile: clientProfile,
                            tokenPresent: !(tokenValue ?? "").isEmpty)

let server = Server(
    name: clientProfile.map { MCPConfigWriter.serverName(profile: $0) } ?? "kastellan",
    version: KastellanCore.version,
    capabilities: .init(tools: .init(listChanged: true))
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: await toolServer.tools())
}

await server.withMethodHandler(CallTool.self) { params in
    await toolServer.call(params.name, arguments: params.arguments)
}

#if os(Windows)
let transport = LineStdioTransport()
#else
let transport = StdioTransport()
#endif
do {
    try await server.start(transport: transport)
} catch {
    await Telemetry.shared.capture(error, level: .fatal, tags: ["phase": "start"])
    await Telemetry.shared.flush()
    throw error
}

// Rechte oder Verbindungen geändert (App): Client soll die Tool-Liste neu holen.
let changeWatcher = DirectoryWatcher(paths: [AppPaths.policiesDirectory.path, AppPaths.home.path]) {
    Task { try? await server.notify(ToolListChangedNotification.message()) }
}
_ = changeWatcher

await server.waitUntilCompleted()
await Telemetry.shared.flush()
crashReporter.disarm()

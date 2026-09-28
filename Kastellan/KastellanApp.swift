import SwiftUI
import KastellanCore

/// Aktivierung beim Start; das Fenster kommt über die WindowGroup (auch bei Klick auf das Dock-Symbol).
/// Absturzerkennung: Marker beim Start, Entfernen beim sauberen Ende, Meldung beim nächsten Start.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let crashReporter = CrashReporter(component: "app")

    override init() {
        // Keine Fensterwiederherstellung: sonst startet die App ohne Fenster, wenn sie mit
        // geschlossenem Fenster beendet wurde. Ein Fenster gibt es beim Start immer.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await Telemetry.shared.configure(component: "app")
            await crashReporter.checkAndArm(processName: "Kastellan")
        }
        crashReporter.handleTerminationSignals {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Foundation.Notification) {
        crashReporter.disarm()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct KastellanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var settings = AppSettings()
    @State private var updater = UpdaterController.shared

    var body: some Scene {
        // Die WindowGroup muss die erste Szene sein: SwiftUI öffnet beim Start nur die erste Fensterszene.
        // Steht MenuBarExtra vorn, gilt die App als reine Menüleisten-App und startet ohne Fenster.
        WindowGroup("Kastellan", id: "main") {
            MainWindow(model: model, settings: settings)
                .environment(\.textScale, settings.textScale)
                .environment(\.font, Font.system(size: Font.TextStyle.body.baseSize * settings.textScale))
                .onAppear { settings.windowVisible = true }
                .onDisappear { settings.windowVisible = false }
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen …") { updater.checkForUpdates() }
                    .disabled(!updater.isAvailable)
            }
            CommandMenu("Darstellung") {
                Button("Schrift größer") { settings.increaseText() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(!settings.canIncreaseText)
                Button("Schrift kleiner") { settings.decreaseText() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!settings.canDecreaseText)
                Button("Standardgröße") { settings.resetText() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: $settings.showInMenuBar) {
            MenuBarView(model: model)
                .environment(\.textScale, settings.textScale)
                .environment(\.font, Font.system(size: Font.TextStyle.body.baseSize * settings.textScale))
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Zustand der App. Ein Runtime für alle Bereiche, Daten werden pro Bereich nachgeladen.
@Observable
@MainActor
final class AppModel {
    let runtime: Runtime
    let service: ActionService

    var profiles: [KastellanProfile] = []
    var selectedProfileID: String?
    var connections: [Connection] = []
    var assignments: [Assignment] = []
    var health: [String: HealthStatus] = [:]
    var tokens: [ClientToken] = []
    var pendingActions: [PendingAction] = []
    var recentActions: [PendingAction] = []
    /// Freigaben, die gerade ausgeführt werden. Verhindert Doppelklicks.
    var inFlight: Set<String> = []
    var lastError: String?
    /// Übergaben aus dem MCP-Server, die auf Ablage in Bitwarden oder 1Password warten.
    var handoffs: [CredentialHandoff] = []
    /// Bitwarden-Session, nur im Speicher.
    var bitwardenSession: String?

    private var watcher: PendingWatcher?
    private var handoffWatcher: PendingWatcher?

    var bitwardenSink: BitwardenSink { BitwardenSink(session: bitwardenSession) }
    var onePasswordSink: OnePasswordSink { OnePasswordSink() }

    enum Section: String, CaseIterable, Identifiable {
        case overview, connections, mcp, permissions, approvals, settings, audit, help
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Übersicht"
            case .connections: "Verbindungen"
            case .mcp: "MCP-Clients"
            case .permissions: "Rechte"
            case .approvals: "Freigaben"
            case .settings: "Einstellungen"
            case .audit: "Protokoll"
            case .help: "Hilfe"
            }
        }
        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .connections: "server.rack"
            case .mcp: "link"
            case .permissions: "lock.shield"
            case .approvals: "checkmark.seal"
            case .settings: "gearshape"
            case .audit: "list.bullet.rectangle"
            case .help: "questionmark.circle"
            }
        }
    }

    init() {
        let rt = (try? Runtime.standard(registry: BuiltinAdapters.registry)) ?? Runtime(registry: BuiltinAdapters.registry)
        runtime = rt
        service = ActionService(runtime: rt)
        watcher = PendingWatcher(directory: AppPaths.pendingDirectory) { [weak self] in
            Task { @MainActor in await self?.reloadPending() }
        }
        handoffWatcher = PendingWatcher(directory: AppPaths.handoffDirectory) { [weak self] in
            Task { @MainActor in await self?.reloadHandoffs(); await self?.processHandoffs() }
        }
        Task { await reloadAll() }
    }

    var version: String { KastellanCore.version }
    var tokenStore: TokenStore { runtime.tokens }
    var profileStore: ProfileStore { runtime.profiles }
    var connectionStore: ConnectionStore { runtime.connections }

    var selectedProfile: KastellanProfile? {
        profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    var profileConnections: [Connection] {
        connections.filter { $0.profileID == selectedProfile?.id }
    }

    var profileTokens: [ClientToken] {
        tokens.filter { $0.profileID == selectedProfile?.id && !$0.isRevoked }
    }

    func reloadAll() async {
        await reloadProfiles()
        await reloadConnections()
        await reloadTokens()
        await reloadPending()
        await reloadHandoffs()
    }

    func reloadHandoffs() async {
        let known = Set(handoffs.map(\.id))
        handoffs = (try? await runtime.handoffs.list()) ?? []
        if let newest = handoffs.last(where: { !known.contains($0.id) }), !known.isEmpty || handoffs.count == 1 {
            Notifier.notify(title: "Kastellan: Zugang wartet auf Ablage", body: "\(newest.record.title) → \(newest.kind.displayName)")
        }
    }

    // MARK: Passwort-Ablage

    func unlockBitwarden(masterPassword: String) async throws {
        bitwardenSession = try await BitwardenSink().unlock(masterPassword: masterPassword)
        await processHandoffs()
    }

    func lockBitwarden() async {
        await bitwardenSink.lock()
        bitwardenSession = nil
    }

    private var processingHandoffs = false

    /// Wartende Übergaben in den Tresor schreiben, soweit dieser gerade erreichbar ist.
    /// Automatische Läufe (Beobachter, Entsperren) lassen bereits gescheiterte Übergaben liegen,
    /// damit ein Fehler nicht in einer Schleife wiederholt wird; „Jetzt ablegen“ versucht alles erneut.
    func processHandoffs(retryFailed: Bool = false) async {
        guard !processingHandoffs else { return }
        processingHandoffs = true
        defer { processingHandoffs = false }
        var failures: [String] = []
        for h in handoffs where retryFailed || h.lastError == nil {
            let sink: any CredentialSink
            switch h.kind {
            case .bitwarden:
                guard bitwardenSession != nil else { continue }
                sink = bitwardenSink
            case .onepassword:
                guard onePasswordSink.isInstalled else { continue }
                sink = onePasswordSink
            default:
                sink = KeychainCredentialSink()
            }
            do {
                let record = try await runtime.handoffs.record(for: h)
                let where_ = try await sink.store(record, target: h.target)
                try await runtime.handoffs.remove(h)
                try? runtime.audit.append(AuditEntry(client: "Kastellan.app", connectionID: h.record.connectionID, tool: "credential_store",
                                                    capability: nil, target: h.record.identifier, outcome: .ok, message: where_))
            } catch {
                let reason = Self.handoffHint(error.localizedDescription)
                try? await runtime.handoffs.markFailed(h, error: reason)
                try? runtime.audit.append(AuditEntry(client: "Kastellan.app", connectionID: h.record.connectionID, tool: "credential_store",
                                                    capability: nil, target: h.record.identifier, outcome: .error, message: reason))
                failures.append("\(h.record.title): \(reason)")
            }
        }
        await reloadHandoffs()
        if retryFailed, !failures.isEmpty {
            lastError = "Ablage fehlgeschlagen.\n" + failures.joined(separator: "\n")
        }
    }

    /// Übersetzt typische CLI-Fehler in einen Hinweis, was zu tun ist.
    static func handoffHint(_ text: String) -> String {
        if text.contains("not logged in") {
            return "Bitwarden-CLI ist abgemeldet. Im Terminal „bw login“ ausführen, dann in den Einstellungen entsperren."
        }
        if text.contains("Vault is locked") {
            return "Bitwarden ist gesperrt. In den Einstellungen mit dem Master-Passwort entsperren."
        }
        return text
    }

    func reloadProfiles() async {
        profiles = (try? await runtime.profiles.list()) ?? []
        if selectedProfileID == nil { selectedProfileID = profiles.first?.id }
    }

    func reloadConnections() async {
        connections = (try? await runtime.connections.list()) ?? []
        assignments = (try? await runtime.assignments.list()) ?? []
        health = (try? runtime.health.latest()) ?? [:]
    }

    var profileAssignments: [Assignment] {
        assignments.filter { $0.profileID == selectedProfile?.id }
    }

    func saveAssignment(_ a: Assignment) async throws {
        try await runtime.assignments.upsert(a)
        await reloadConnections()
    }

    func deleteAssignment(_ a: Assignment) async {
        try? await runtime.assignments.delete(id: a.id)
        await reloadConnections()
    }

    func reloadTokens() async {
        tokens = (try? await runtime.tokens.list()) ?? []
    }

    func reloadPending() async {
        let all = (try? await runtime.pending.list(includeFinal: true)) ?? []
        let open = all.filter { !$0.status.isFinal }
        if open.count > pendingActions.count, let newest = open.last {
            Notifier.notify(title: "Kastellan: Freigabe nötig", body: newest.preview)
        }
        pendingActions = open
        recentActions = Array(all.filter { $0.status.isFinal }.suffix(20).reversed())
    }

    func profileName(_ id: String) -> String {
        profiles.first { $0.id == id }?.name ?? id
    }

    /// Warum ein Profil nicht gelöscht werden kann, oder nil.
    func profileDeleteBlocker(_ ctx: KastellanProfile) -> String? {
        let conns = connections.filter { $0.profileID == ctx.id }.count
        let toks = tokens.filter { $0.profileID == ctx.id && !$0.isRevoked }.count
        if conns > 0 { return "\(conns) Verbindung(en) im Profil, zuerst löschen." }
        if toks > 0 { return "\(toks) aktive(s) Token im Profil, zuerst widerrufen." }
        if profiles.count <= 1 { return "Der letzte Profil bleibt bestehen." }
        return nil
    }

    func deleteProfile(_ ctx: KastellanProfile) async {
        guard profileDeleteBlocker(ctx) == nil else { return }
        do {
            try await runtime.profiles.delete(id: ctx.id)
            await reloadProfiles()
            if selectedProfileID == ctx.id { selectedProfileID = profiles.first?.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func renameProfile(_ ctx: KastellanProfile, to name: String) async {
        do {
            try await runtime.profiles.rename(id: ctx.id, to: name)
            await reloadProfiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func connectionLabel(_ id: String) -> String {
        connections.first { $0.id == id }?.label ?? id
    }

    // MARK: Verbindungen

    func saveConnection(_ connection: Connection, secrets: [String: String]) async throws {
        try await runtime.connections.upsert(connection)
        for (key, value) in secrets {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            try await runtime.secrets.set(connectionID: connection.id, key: key, value: trimmed)
        }
        await reloadConnections()
        await checkHealth(connection)
    }

    func deleteConnection(_ connection: Connection) async throws {
        try await runtime.connections.delete(id: connection.id)
        try await runtime.policies.removeConnection(connection.id)
        try await runtime.assignments.removeConnection(connection.id)
        if let keychain = runtime.secrets as? KeychainSecretStore {
            try keychain.deleteAll(connectionID: connection.id)
        }
        await reloadConnections()
    }

    func checkHealth(_ connection: Connection) async {
        do {
            let adapter = try runtime.registry.adapter(for: connection, secrets: runtime.secrets)
            let status = await adapter.healthCheck()
            try runtime.health.append(status)
        } catch {
            try? runtime.health.append(HealthStatus(connectionID: connection.id, ok: false, message: error.localizedDescription))
            await Telemetry.shared.capture(error, tags: ["phase": "health", "provider": connection.provider])
        }
        health = (try? runtime.health.latest()) ?? [:]
    }

    // MARK: Freigaben

    func canDecide(_ action: PendingAction) -> Bool {
        action.status == .prepared && !inFlight.contains(action.id)
    }

    func approve(_ action: PendingAction) async {
        guard canDecide(action) else { return }
        inFlight.insert(action.id)
        defer { inFlight.remove(action.id) }
        do {
            _ = try await service.approve(pendingID: action.id, by: "\(NSFullUserName()) (Kastellan.app)")
        } catch {
            lastError = error.localizedDescription
            await Telemetry.shared.capture(error, tags: ["phase": "approve", "capability": action.capability.description])
        }
        await reloadPending()
    }

    func reject(_ action: PendingAction) async {
        guard canDecide(action) else { return }
        inFlight.insert(action.id)
        defer { inFlight.remove(action.id) }
        do {
            _ = try await service.reject(pendingID: action.id, by: "\(NSFullUserName()) (Kastellan.app)")
        } catch {
            lastError = error.localizedDescription
        }
        await reloadPending()
    }
}

/// Symbol in der Menüleiste. Öffnet beim ersten Start das Fenster, damit die App nicht unsichtbar bleibt.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label {
            Text("Kastellan")
        } icon: {
            Image(systemName: model.pendingActions.isEmpty ? "key.horizontal" : "key.horizontal.fill")
        }
        .labelStyle(.iconOnly)
        .task { await model.reloadAll() }
    }
}

struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kastellan \(model.version)").kFont(.headline)
            Text("\(model.connections.count) Verbindungen, \(model.pendingActions.count) offene Freigaben")
                .kFont(.caption)
                .foregroundStyle(.secondary)
            if !model.pendingActions.isEmpty {
                Divider()
                ForEach(model.pendingActions.prefix(5)) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.preview).kFont(.callout).lineLimit(2)
                        HStack {
                            Text("\(action.client), \(model.connectionLabel(action.connectionID))").kFont(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if model.canDecide(action) {
                                Button("Freigeben") { Task { await model.approve(action) } }.controlSize(.small)
                                Button("Verwerfen") { Task { await model.reject(action) } }.controlSize(.small)
                            } else {
                                ProgressView().controlSize(.small)
                                Text("läuft").kFont(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Fenster öffnen") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("Beenden") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
    }
}

struct MainWindow: View {
    let model: AppModel
    let settings: AppSettings
    /// Startbereich, per `--section <name>` wählbar (Screenshots, Fehlersuche).
    @State private var selection: AppModel.Section? = {
        if let i = CommandLine.arguments.firstIndex(of: "--section"), i + 1 < CommandLine.arguments.count,
           let s = AppModel.Section(rawValue: CommandLine.arguments[i + 1]) { return s }
        return .overview
    }()

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $selection) { section in
                Label {
                    HStack {
                        Text(section.title)
                        if section == .approvals, !model.pendingActions.isEmpty {
                            Spacer()
                            Text("\(model.pendingActions.count)")
                                .kFont(.caption2, weight: .bold).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.gold, in: Capsule()).foregroundStyle(Theme.navy)
                        }
                    }
                } icon: {
                    Image(systemName: section.symbol)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    ProfilePicker(model: model)
                    Wordmark(size: 15).padding(.top, 4)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sidebar)
            }
            .task { await model.reloadAll() }
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview:
                    // Banner bis an den Fensterrand: Titelleiste bleibt (Ampeln, Seitenleisten-Schalter),
                    // nur ihr Hintergrund verschwindet, wie bei TorroMail.
                    OverviewView(model: model) { selection = $0 }
                        .navigationTitle("")
                        .toolbarBackground(.hidden, for: .windowToolbar)
                        .ignoresSafeArea(edges: .top)
                case .connections: titled(.connections) { ConnectionsView(model: model) }
                case .permissions: titled(.permissions) { PermissionsView(model: model) }
                case .approvals: titled(.approvals) { ApprovalsView(model: model) }
                case .audit: titled(.audit) { AuditView(model: model) }
                case .mcp: titled(.mcp) { MCPSettingsView(model: model) }
                case .settings: titled(.settings) { SettingsView(settings: settings, settingsModel: model) { selection = $0 } }
                case .help: titled(.help) { HelpView() }
                }
            }
            .background(Theme.background)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.gold)
        .alert("Fehler", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

extension MainWindow {
    /// Bereichstitel in der Titelleiste, wie bei TorroMail.
    @ViewBuilder
    func titled<Content: View>(_ section: AppModel.Section, @ViewBuilder content: () -> Content) -> some View {
        content()
            .navigationTitle(section.title)
            .toolbarBackground(Theme.background, for: .windowToolbar)
    }
}

/// Profil-Auswahl (Privat, Beruflich, ...). Gilt für Verbindungen, Rechte und MCP-Einträge.
struct ProfilePicker: View {
    @Bindable var model: AppModel
    @State private var newName = ""
    @State private var showNew = false
    @State private var renameText = ""
    @State private var showRename = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Profil").kFont(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Profil", selection: $model.selectedProfileID) {
                    ForEach(model.profiles) { ctx in
                        Text(ctx.name).tag(Optional(ctx.id))
                    }
                }
                .labelsHidden()
                Menu {
                    Button("Neuer Profil") { showNew = true }
                    if let ctx = model.selectedProfile {
                        Button("„\(ctx.name)“ umbenennen") { renameText = ctx.name; showRename = true }
                        if let why = model.profileDeleteBlocker(ctx) {
                            Text("Löschen nicht möglich: \(why)")
                        } else {
                            Button("„\(ctx.name)“ löschen", role: .destructive) { confirmDelete = true }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .popover(isPresented: $showRename) {
                    HStack {
                        TextField("Neuer Name", text: $renameText).frame(width: 160)
                        Button("Umbenennen") {
                            if let ctx = model.selectedProfile {
                                Task { await model.renameProfile(ctx, to: renameText); showRename = false }
                            }
                        }
                        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding()
                }
                .confirmationDialog("Profil „\(model.selectedProfile?.name ?? "")“ löschen?", isPresented: $confirmDelete) {
                    Button("Löschen", role: .destructive) {
                        if let ctx = model.selectedProfile { Task { await model.deleteProfile(ctx) } }
                    }
                } message: {
                    Text("Der Profil ist leer, Policy-Dateien mit seinem Namen bleiben als Dateien liegen.")
                }
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .popover(isPresented: $showNew) {
                        HStack {
                            TextField("Neuer Profil", text: $newName).frame(width: 160)
                            Button("Anlegen") {
                                Task {
                                    if let ctx = try? await model.profileStore.create(name: newName) {
                                        await model.reloadProfiles()
                                        model.selectedProfileID = ctx.id
                                        newName = ""
                                        showNew = false
                                    }
                                }
                            }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding()
                    }
            }
        }
    }
}

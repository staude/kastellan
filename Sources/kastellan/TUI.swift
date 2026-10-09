import Foundation
import KastellanCore

/// Ereignisse der Hauptschleife: Tasten und Neuzeichnen nach Hintergrundarbeit oder Dateiänderungen.
enum Event: Sendable {
    case key(Key)
    case refresh
}

/// Terminal-Oberfläche von Kastellan. Dieselben Daten wie die macOS-App (Kastellan-Home, Secrets der
/// Plattform), dieselben Bereiche ohne Hilfe und Einstellungen.
@MainActor
final class TUI {
    enum Section: Int, CaseIterable {
        case overview, connections, permissions, clients, approvals, audit
        var title: String {
            switch self {
            case .overview: "Übersicht"
            case .connections: "Verbindungen"
            case .permissions: "Rechte"
            case .clients: "MCP-Clients"
            case .approvals: "Freigaben"
            case .audit: "Protokoll"
            }
        }
    }

    /// Modaler Dialog über dem Bereich.
    enum Modal {
        case form(Form)
        case confirm(String, @MainActor () async -> Void)
        case message(String, [String])
        case input(String, String, @MainActor (String) async -> Void)
        case choice(String, [String], Int, @MainActor (Int) async -> Void)
    }

    let runtime: Runtime
    let service: ActionService
    let terminal = Terminal()
    var events: AsyncStream<Event>.Continuation?

    var section: Section = .overview
    var profiles: [KastellanProfile] = []
    var profileIndex = 0
    var connections: [Connection] = []
    var tokens: [ClientToken] = []
    var pending: [PendingAction] = []
    var finished: [PendingAction] = []
    var health: [String: HealthStatus] = [:]
    var audit: [AuditEntry] = []

    var selection: [Section: Int] = [:]
    var permToken = 0
    var permConnection = 0
    var policy = Policy()
    var modal: Modal?
    var status: String?
    var busy: Set<String> = []
    var running = true
    private var watcher: DirectoryWatcher?

    init() throws {
        runtime = try Runtime.standard(registry: BuiltinAdapters.registry)
        service = ActionService(runtime: runtime)
    }

    var profile: KastellanProfile? { profiles.indices.contains(profileIndex) ? profiles[profileIndex] : profiles.first }
    var profileConnections: [Connection] { connections.filter { $0.profileID == profile?.id } }
    var profileTokens: [ClientToken] { tokens.filter { $0.profileID == profile?.id && !$0.isRevoked } }
    var user: String {
        let env = ProcessInfo.processInfo.environment
        return (env["USER"] ?? env["USERNAME"] ?? "Terminal") + " (kastellan TUI)"
    }

    // MARK: - Ablauf

    func run() async {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        events = continuation
        terminal.start()
        defer { terminal.stop() }
        terminal.keys { key in continuation.yield(.key(key)) }
        watcher = DirectoryWatcher(paths: [AppPaths.pendingDirectory.path, AppPaths.policiesDirectory.path, AppPaths.home.path]) {
            continuation.yield(.refresh)
        }
        let ticker = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); continuation.yield(.refresh) } }
        defer { ticker.cancel() }
        await reload()
        draw()
        for await event in stream {
            switch event {
            case .key(let key): await handle(key)
            case .refresh: await reload(light: true)
            }
            guard running else { break }
            draw()
        }
    }

    func reload(light: Bool = false) async {
        profiles = (try? await runtime.profiles.list()) ?? []
        connections = (try? await runtime.connections.list()) ?? []
        tokens = (try? await runtime.tokens.list()) ?? []
        let all = (try? await runtime.pending.list(includeFinal: true)) ?? []
        pending = all.filter { !$0.status.isFinal }
        finished = Array(all.filter { $0.status.isFinal }.suffix(15).reversed())
        health = (try? runtime.health.latest()) ?? [:]
        audit = Array(((try? runtime.audit.entries(AuditFilter(limit: 300))) ?? []).reversed())
        if !light { await loadPolicy() }
    }

    func background(_ id: String, _ work: @escaping @MainActor () async -> Void) {
        busy.insert(id)
        Task { @MainActor in
            await work()
            busy.remove(id)
            await reload(light: true)
            events?.yield(.refresh)
        }
    }

    func label(of connectionID: String) -> String { connections.first { $0.id == connectionID }?.label ?? connectionID }

    // MARK: - Tasten

    func handle(_ key: Key) async {
        status = nil
        if let modal {
            await handleModal(key, modal)
            return
        }
        switch key {
        case .char("q"), .ctrl("c"):
            running = false
            return
        case .char(let c) where ("1"..."6").contains(c):
            section = Section(rawValue: Int(String(c))! - 1) ?? .overview
            await loadPolicy()
            return
        case .tab:
            section = Section(rawValue: (section.rawValue + 1) % Section.allCases.count)!
            await loadPolicy()
            return
        case .backTab:
            section = Section(rawValue: (section.rawValue + Section.allCases.count - 1) % Section.allCases.count)!
            await loadPolicy()
            return
        case .char("P"):
            guard profiles.count > 1 else { status = "Nur ein Profil vorhanden."; return }
            profileIndex = (profileIndex + 1) % profiles.count
            permToken = 0; permConnection = 0
            await loadPolicy()
            return
        case .char("r"):
            await reload()
            status = "Neu geladen."
            return
        default:
            break
        }
        switch section {
        case .overview: break
        case .connections: await connectionsKey(key)
        case .permissions: await permissionsKey(key)
        case .clients: await clientsKey(key)
        case .approvals: await approvalsKey(key)
        case .audit: moveSelection(key, count: audit.count)
        }
    }

    func moveSelection(_ key: Key, count: Int) {
        var i = selection[section] ?? 0
        switch key {
        case .up, .char("k"): i -= 1
        case .down, .char("j"): i += 1
        case .pageUp: i -= 10
        case .pageDown: i += 10
        case .home: i = 0
        case .end: i = count - 1
        default: return
        }
        selection[section] = max(0, min(i, count - 1))
    }

    func selected(_ count: Int) -> Int? {
        guard count > 0 else { return nil }
        let i = min(selection[section] ?? 0, count - 1)
        selection[section] = i
        return i
    }

    func handleModal(_ key: Key, _ current: Modal) async {
        switch current {
        case .message:
            modal = nil
        case .confirm(_, let action):
            if key == .char("j") || key == .char("y") || key == .char("J") || key == .char("Y") {
                modal = nil
                await action()
            } else if key == .char("n") || key == .escape || key == .char("N") {
                modal = nil
            }
        case .input(let title, var text, let action):
            switch key {
            case .escape: modal = nil
            case .enter: modal = nil; await action(text)
            case .backspace: text = String(text.dropLast()); modal = .input(title, text, action)
            case .char(let c): text.append(c); modal = .input(title, text, action)
            default: break
            }
        case .choice(let title, let options, var index, let action):
            switch key {
            case .escape: modal = nil
            case .up: index = max(0, index - 1); modal = .choice(title, options, index, action)
            case .down: index = min(options.count - 1, index + 1); modal = .choice(title, options, index, action)
            case .enter: modal = nil; await action(index)
            default: break
            }
        case .form(let form):
            await form.handle(key, tui: self)
        }
    }
}

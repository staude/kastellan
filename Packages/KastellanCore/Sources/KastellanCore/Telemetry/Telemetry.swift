import Foundation

/// Fehler-Telemetrie an GlitchTip (Sentry-Store-API), ohne Fremdpaket.
///
/// Gemeldet werden nur Fehler und Warnungen: Typ, Meldung, Komponente, Provider, Aktion. Nie Passwörter,
/// Tokens oder Parameter. Standardmäßig aus; eingeschaltet über die Einstellungen (`{"enabled": true}` in
/// `<Home>/telemetry.json`), `KASTELLAN_TELEMETRY=on` oder eine eigene `KASTELLAN_SENTRY_DSN`. Ziel ist die
/// eigene DSN, sonst die eingebaute Instanz des Projekts.
public actor Telemetry {
    public static let shared = Telemetry()

    public struct DSN: Sendable, Equatable {
        public let key: String
        public let storeURL: URL

        /// `https://<key>@host/<projekt>` → `https://host/api/<projekt>/store/`
        public init?(_ text: String) {
            guard let url = URL(string: text), let host = url.host, let key = url.user, !key.isEmpty else { return nil }
            let project = url.lastPathComponent
            guard !project.isEmpty, project != "/" else { return nil }
            var comps = URLComponents()
            comps.scheme = url.scheme
            comps.host = host
            comps.port = url.port
            comps.path = "/api/\(project)/store/"
            guard let store = comps.url else { return nil }
            self.key = key
            self.storeURL = store
        }
    }

    public enum Level: String, Sendable { case fatal, error, warning, info }

    public static let defaultDSN = "https://a72bba9093ea458e81780d0b490356ed@telemetrie.staude.cc/1"

    private var dsn: DSN?
    private var breadcrumbSource: (@Sendable (Date) -> [Breadcrumb])?
    private var component = "core"
    private var environment = "production"
    private var enabled = false
    private var session: URLSession = .shared
    private var inFlight: [Task<Void, Never>] = []
    /// Letzter HTTP-Status der Store-API, für Diagnose.
    public private(set) var lastStatus: String = "noch nichts gesendet"
    /// Postausgang für Events, die nicht zugestellt werden konnten (Netz weg, DNS, Server nicht erreichbar).
    static var outboxDirectory: URL { AppPaths.home.appendingPathComponent("telemetry-outbox", isDirectory: true) }

    /// Ein Breadcrumb im Sentry-Format, aus dem Audit-Log abgeleitet.
    public struct Breadcrumb: Sendable {
        public var timestamp: Date
        public var category: String
        public var message: String
        public var level: Level
        public var data: [String: String]

        public init(timestamp: Date, category: String, message: String, level: Level, data: [String: String] = [:]) {
            self.timestamp = timestamp; self.category = category; self.message = message; self.level = level; self.data = data
        }
    }

    /// Einmal beim Start je Prozess. `component` ist `app` oder `mcp`. `audit` liefert die Breadcrumbs.
    public func configure(component: String, session: URLSession = .shared, audit: AuditLog? = AuditLog()) {
        self.component = component
        self.session = session
        if let audit {
            breadcrumbSource = { until in Self.breadcrumbs(from: audit, until: until) }
        }
        let env = ProcessInfo.processInfo.environment
        guard Self.isOptedIn(environment: env, fileSetting: Self.settingFromFile()) else {
            enabled = false
            return
        }
        dsn = DSN(env["KASTELLAN_SENTRY_DSN"] ?? Self.defaultDSN)
        enabled = dsn != nil
        #if DEBUG
        environment = "development"
        #else
        environment = "production"
        #endif
        drainOutbox()
    }

    /// Liegen gebliebene Events nachliefern (höchstens 50, älteste zuerst).
    public func drainOutbox() {
        guard enabled, let dsn else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Self.outboxDirectory.path) else { return }
        for name in names.filter({ $0.hasSuffix(".json") }).sorted().prefix(50) {
            let url = Self.outboxDirectory.appendingPathComponent(name)
            guard let body = try? Data(contentsOf: url) else { continue }
            post(body, dsn: dsn, outboxFile: url)
        }
    }

    public func outboxCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: Self.outboxDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    public var isEnabled: Bool { enabled }
    public var storeURLDescription: String { dsn?.storeURL.absoluteString ?? "keine DSN" }

    /// Fehler melden. `tags` sind kurze Schlüssel (provider, tool, capability), keine Nutzdaten.
    public func capture(_ error: Error, level: Level = .error, tags: [String: String] = [:], extra: [String: String] = [:]) {
        guard enabled else { return }
        let type: String
        let value: String
        if let k = error as? KastellanError {
            type = "KastellanError.\(k.caseName)"
            value = k.localizedDescription
        } else {
            type = String(describing: Swift.type(of: error))
            value = error.localizedDescription
        }
        var e = Self.event(level: level, message: nil, exceptionType: type, exceptionValue: Self.scrub(value),
                           component: component, environment: environment, tags: tags, extra: extra.mapValues(Self.scrub))
        attachBreadcrumbs(&e, until: Date())
        send(e)
    }

    public func capture(message: String, level: Level = .warning, tags: [String: String] = [:], extra: [String: String] = [:]) {
        guard enabled else { return }
        var e = Self.event(level: level, message: Self.scrub(message), exceptionType: nil, exceptionValue: nil,
                           component: component, environment: environment, tags: tags, extra: extra.mapValues(Self.scrub))
        attachBreadcrumbs(&e, until: Date())
        send(e)
    }

    /// Ein Frame eines Stacktraces, ältester zuerst (Sentry-Konvention: der auslösende Frame steht am Ende).
    public struct Frame: Sendable {
        public var module: String
        public var function: String
        public var file: String?
        public var line: Int?
        public var inApp: Bool

        public init(module: String, function: String, file: String? = nil, line: Int? = nil, inApp: Bool) {
            self.module = module; self.function = function; self.file = file; self.line = line; self.inApp = inApp
        }
    }

    /// Absturz mit Stacktrace melden. `frames` in Aufrufreihenfolge (ältester zuerst).
    public func captureCrash(type: String, value: String, frames: [Frame], occurredAt: Date?, tags: [String: String] = [:],
                             extra: [String: String] = [:], device: [String: String] = [:]) {
        guard enabled else { return }
        var e = Self.event(level: .fatal, message: nil, exceptionType: type, exceptionValue: Self.scrub(value),
                           component: component, environment: environment, tags: tags, extra: extra.mapValues(Self.scrub))
        if let occurredAt { e["timestamp"] = ISO8601DateFormatter().string(from: occurredAt) }
        let frameList: [[String: Any]] = frames.map { f in
            var d: [String: Any] = ["module": f.module, "function": f.function, "in_app": f.inApp]
            if let file = f.file { d["filename"] = file }
            if let line = f.line { d["lineno"] = line }
            return d
        }
        e["exception"] = ["values": [["type": type, "value": Self.scrub(value), "stacktrace": ["frames": frameList], "mechanism": ["type": "crash_report", "handled": false]]]]
        // Gruppierung nach Fehlertyp und oberstem App-Frame, nicht nach Meldungstext.
        let top = frames.last(where: \.inApp)?.function ?? frames.last?.function ?? "?"
        e["fingerprint"] = ["crash", type, top]
        if !device.isEmpty, var contexts = e["contexts"] as? [String: Any] {
            contexts["device"] = device
            e["contexts"] = contexts
        }
        attachBreadcrumbs(&e, until: occurredAt ?? Date())
        send(e)
    }

    private func attachBreadcrumbs(_ e: inout [String: Any], until: Date) {
        guard let source = breadcrumbSource else { return }
        let crumbs = source(until)
        guard !crumbs.isEmpty else { return }
        e["breadcrumbs"] = ["values": crumbs.map { c -> [String: Any] in
            var d: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: c.timestamp), "type": "default",
                                    "category": c.category, "message": Self.scrub(c.message), "level": c.level.rawValue]
            if !c.data.isEmpty { d["data"] = c.data.mapValues(Self.scrub) }
            return d
        }]
    }

    /// Die letzten 20 Audit-Einträge der letzten 30 Minuten vor `until`.
    static func breadcrumbs(from audit: AuditLog, until: Date, limit: Int = 20) -> [Breadcrumb] {
        let entries = (try? audit.entries(AuditFilter(since: until.addingTimeInterval(-1800), limit: .max))) ?? []
        return entries.filter { $0.timestamp <= until.addingTimeInterval(1) }.suffix(limit).map { e in
            let level: Level = switch e.outcome {
            case .ok, .confirmed, .pending: .info
            case .cancelled, .denied, .outOfScope, .unsupported: .warning
            case .error: .error
            }
            var data: [String: String] = ["outcome": e.outcome.rawValue, "client": e.client]
            if let id = e.connectionID { data["connection_id"] = id }
            if let ms = e.durationMS { data["duration_ms"] = String(ms) }
            if let m = e.message { data["message"] = m }
            if let p = e.pendingActionID { data["pending_action_id"] = p }
            let what = e.tool ?? e.capability?.description ?? "?"
            return Breadcrumb(timestamp: e.timestamp, category: "audit",
                              message: e.target.map { "\(what) \($0)" } ?? what, level: level, data: data)
        }
    }

    /// Auf laufende Sendungen warten, etwa vor Prozessende (höchstens `timeout` Sekunden).
    public func flush(timeout: TimeInterval = 2) async {
        let tasks = inFlight
        inFlight = []
        let deadline = Task { try? await Task.sleep(for: .seconds(timeout)) }
        for t in tasks {
            if deadline.isCancelled { break }
            await t.value
        }
        deadline.cancel()
    }

    // MARK: - Intern

    private func send(_ payload: [String: Any]) {
        guard let dsn, let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        post(body, dsn: dsn, outboxFile: nil)
    }

    /// Sendet ein Event. Scheitert die Zustellung, landet es im Postausgang (falls es nicht schon von dort kommt).
    private func post(_ body: Data, dsn: DSN, outboxFile: URL?) {
        var req = URLRequest(url: dsn.storeURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Sentry sentry_version=7, sentry_key=\(dsn.key), sentry_client=kastellan/\(KastellanCore.version)", forHTTPHeaderField: "X-Sentry-Auth")
        req.httpBody = body
        let session = self.session
        let task = Task.detached(priority: .utility) { [req, body, outboxFile] in
            var delivered = false
            var status = ""
            do {
                let (_, response) = try await session.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                status = "HTTP \(code)"
                delivered = (200..<300).contains(code) || code == 429 || code == 413 || code == 400
            } catch {
                let ns = error as NSError
                let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (\($0.domain) \($0.code))" } ?? ""
                status = "Fehler: \(error.localizedDescription) [\(ns.domain) \(ns.code)\(underlying)] URL \(req.url?.absoluteString ?? "?")"
            }
            if delivered {
                if let outboxFile { try? FileManager.default.removeItem(at: outboxFile) }
            } else if outboxFile == nil {
                let dir = Telemetry.outboxDirectory
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
                try? body.write(to: dir.appendingPathComponent(name), options: .atomic)
                status += ", im Postausgang abgelegt"
            }
            await Telemetry.shared.record(status: status)
        }
        inFlight.append(task)
        if inFlight.count > 32 { inFlight.removeFirst(inFlight.count - 32) }
    }

    func record(status: String) { lastStatus = status }

    static func event(level: Level, message: String?, exceptionType: String?, exceptionValue: String?,
                      component: String, environment: String, tags: [String: String], extra: [String: String]) -> [String: Any] {
        var e: [String: Any] = [
            "event_id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "platform": "other",
            "level": level.rawValue,
            "logger": "kastellan.\(component)",
            "release": "kastellan@\(KastellanCore.version)",
            "environment": environment,
            "server_name": Host.current().localizedName ?? "mac",
            "tags": tags.merging(["component": component, "os": ProcessInfo.processInfo.operatingSystemVersionString]) { a, _ in a },
            "contexts": ["os": ["name": "macOS", "version": ProcessInfo.processInfo.operatingSystemVersionString],
                         "runtime": ["name": "Swift", "version": "6"]],
        ]
        if !extra.isEmpty { e["extra"] = extra }
        if let message { e["message"] = message }
        if let exceptionType {
            e["exception"] = ["values": [["type": exceptionType, "value": exceptionValue ?? ""]]]
        }
        return e
    }

    /// Entfernt Passwörter und Tokens aus Texten, falls sie doch in einer Meldung landen.
    static func scrub(_ text: String) -> String {
        var out = text
        for pattern in [#"(?i)(passw(or)?[dt]|token|secret|kas_auth_data)["']?\s*[:=]\s*["']?[^\s"',}]+"#, #"kastellan_[a-z0-9-]+_[0-9a-f]{48}"#] {
            out = out.replacingOccurrences(of: pattern, with: "$1=***", options: .regularExpression)
        }
        return out
    }

    /// Telemetrie ist aus, bis jemand sie bewusst einschaltet: in den Einstellungen (`telemetry.json`
    /// mit `enabled: true`), mit `KASTELLAN_TELEMETRY=on` oder einer eigenen `KASTELLAN_SENTRY_DSN`.
    /// `KASTELLAN_TELEMETRY=off` und `enabled: false` gewinnen immer.
    static func isOptedIn(environment env: [String: String], fileSetting: Bool?) -> Bool {
        let flag = env["KASTELLAN_TELEMETRY"]?.lowercased()
        if flag == "off" || fileSetting == false { return false }
        if flag == "on" { return true }
        if let custom = env["KASTELLAN_SENTRY_DSN"], !custom.isEmpty { return true }
        return fileSetting == true
    }

    /// `enabled` aus `<Home>/telemetry.json`, `nil` ohne Datei oder Eintrag.
    static func settingFromFile() -> Bool? {
        let url = AppPaths.home.appendingPathComponent("telemetry.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["enabled"] as? Bool
    }
}

extension KastellanError {
    var caseName: String {
        switch self {
        case .invalidArgument: "invalidArgument"
        case .notFound: "notFound"
        case .unauthorized: "unauthorized"
        case .unsupported: "unsupported"
        case .provider: "provider"
        case .internal: "internal"
        }
    }
}

import Foundation

// Client für die Hetzner Cloud API (https://api.hetzner.cloud/v1). Bearer-Token je Projekt,
// JSON rein und raus. Fehler kommen als `{error: {code, message, details}}` und werden zu
// `KastellanError`. Das Rate-Limit (3600/h, ein Aufruf pro Sekunde wächst nach) wird über die
// `RateLimit-*`-Header beobachtet; bei 429 wartet der Client kurz und versucht es einmal erneut.
// Schreibende Aufrufe liefern eine `action`, auf die `waitForAction` bis success/error wartet.
// Aufrufe pro Verbindung laufen seriell.

public actor HetznerClient {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias TokenProvider = @Sendable () async throws -> String

    public static let defaultBaseURL = URL(string: "https://api.hetzner.cloud/v1")!
    /// Seitengröße für Listen (Hetzner erlaubt bis 50).
    public static let pageSize = 50
    /// Längste Wartezeit nach einem 429, bevor der zweite Versuch startet.
    public static let rateLimitRetryCap: Duration = .seconds(5)

    private let baseURL: URL
    private let tokenProvider: TokenProvider
    private let transport: any HetznerTransport
    private let sleep: Sleep
    private let pollInterval: Duration
    private let pollTimeout: Duration
    private let now: @Sendable () -> Date

    /// Letzter Stand von `RateLimit-Remaining`, `nil` bis zur ersten Antwort.
    public private(set) var rateLimitRemaining: Int?

    // Serialisierung: Actor-Methoden sind an `await` reentrant, deshalb eine eigene Warteschlange.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(tokenProvider: @escaping TokenProvider,
                transport: any HetznerTransport = URLSessionHetznerTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                baseURL: URL = HetznerClient.defaultBaseURL,
                pollInterval: Duration = .seconds(1),
                pollTimeout: Duration = .seconds(60),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.sleep = sleep
        self.baseURL = baseURL
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.now = now
    }

    public init(token: String,
                transport: any HetznerTransport = URLSessionHetznerTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                baseURL: URL = HetznerClient.defaultBaseURL,
                pollInterval: Duration = .seconds(1),
                pollTimeout: Duration = .seconds(60)) {
        self.init(tokenProvider: { token }, transport: transport, sleep: sleep, baseURL: baseURL,
                  pollInterval: pollInterval, pollTimeout: pollTimeout)
    }

    // MARK: - Aufrufe

    /// Führt einen Aufruf aus und liefert den JSON-Body (`.null` bei leerer Antwort).
    /// `path` ist relativ zur Basis-URL, etwa `/zones` oder `/servers/42/actions/poweron`.
    @discardableResult
    public func request(_ method: String, _ path: String, query: [(String, String)] = [], body: JSONValue? = nil) async throws -> JSONValue {
        await acquire()
        defer { release() }
        return try await perform(method, path, query: query, body: body, retry: true)
    }

    public func get(_ path: String, query: [(String, String)] = []) async throws -> JSONValue {
        try await request("GET", path, query: query)
    }

    @discardableResult
    public func post(_ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        try await request("POST", path, body: body)
    }

    @discardableResult
    public func put(_ path: String, body: JSONValue) async throws -> JSONValue {
        try await request("PUT", path, body: body)
    }

    @discardableResult
    public func delete(_ path: String) async throws -> JSONValue {
        try await request("DELETE", path)
    }

    /// Liest alle Seiten einer Liste (`page`/`per_page`, `meta.pagination.next_page`) und
    /// liefert die Elemente unter `key` zusammen.
    public func list(_ path: String, key: String, query: [(String, String)] = []) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var page = 1
        while true {
            let q = query + [("page", String(page)), ("per_page", String(Self.pageSize))]
            let response = try await get(path, query: q)
            items += response.array(key)
            guard let next = response["meta"]?["pagination"]?.int("next_page"), next > page else { break }
            page = next
        }
        return items
    }

    /// Wartet, bis eine Action `success` erreicht. `error` wird zu `KastellanError.provider`,
    /// Überschreiten des Timeouts ebenfalls. Bereits abgeschlossene Actions kehren sofort zurück.
    @discardableResult
    public func waitForAction(_ action: JSONValue) async throws -> JSONValue {
        var current = action
        let started = now()
        while true {
            switch current.string("status") {
            case "success":
                return current
            case "error":
                let err = current["error"]
                let code = err?.string("code") ?? "action_failed"
                let message = err?.string("message") ?? "Aktion fehlgeschlagen"
                throw KastellanError.provider("\(current.string("command") ?? "action"): \(code): \(message)")
            default:
                guard let id = current.int("id") else {
                    throw KastellanError.provider("Hetzner: Action ohne ID in der Antwort")
                }
                let elapsed = Duration.seconds(now().timeIntervalSince(started))
                guard elapsed < pollTimeout else {
                    throw KastellanError.provider("Hetzner: Action \(id) (\(current.string("command") ?? "?")) nach \(Int(pollTimeout.components.seconds)) s nicht abgeschlossen")
                }
                try await sleep(pollInterval)
                current = try await get("/actions/\(id)")["action"] ?? .null
            }
        }
    }

    /// Wartet auf `action` und alle `next_actions` einer Antwort, sofern vorhanden.
    public func waitForActions(in response: JSONValue) async throws {
        if let action = response["action"], action != .null {
            try await waitForAction(action)
        }
        for next in response.array("next_actions") {
            try await waitForAction(next)
        }
    }

    // MARK: - Intern

    private func perform(_ method: String, _ path: String, query: [(String, String)], body: JSONValue?, retry: Bool) async throws -> JSONValue {
        let request = try await buildRequest(method, path, query: query, body: body)
        let response = try await transport.send(request)
        if let remaining = response.header("RateLimit-Remaining").flatMap({ Int($0) }) {
            rateLimitRemaining = remaining
        }

        if response.status == 429, retry {
            try await sleep(retryDelay(for: response))
            return try await perform(method, path, query: query, body: body, retry: false)
        }
        guard (200..<300).contains(response.status) else {
            throw Self.error(status: response.status, body: response.body)
        }
        guard !response.body.isEmpty else { return .null }
        do {
            return try JSONCoding.decoder.decode(JSONValue.self, from: response.body)
        } catch {
            throw KastellanError.provider("Hetzner: Antwort ist kein JSON (\(method) \(path))")
        }
    }

    private func buildRequest(_ method: String, _ path: String, query: [(String, String)], body: JSONValue?) async throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw KastellanError.internal("Hetzner: ungültige Basis-URL")
        }
        components.path = baseURL.path + path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else {
            throw KastellanError.invalidArgument("Hetzner: ungültiger Pfad \(path)")
        }
        let token = try await tokenProvider()
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Kastellan/\(KastellanCore.version)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONCoding.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Wartezeit nach 429: bis `RateLimit-Reset`, mindestens eine Sekunde (so lange dauert ein
    /// nachwachsender Aufruf), höchstens `rateLimitRetryCap`.
    private func retryDelay(for response: HetznerResponse) -> Duration {
        let cap = Double(HetznerClient.rateLimitRetryCap.components.seconds)
        guard let reset = response.header("RateLimit-Reset").flatMap({ Double($0) }) else {
            return .seconds(1)
        }
        let seconds = reset - now().timeIntervalSince1970
        return .seconds(min(max(seconds, 1), cap))
    }

    /// Bildet die Fehlerhülle `{error: {code, message}}` auf `KastellanError` ab.
    static func error(status: Int, body: Data) -> KastellanError {
        var code = "http_\(status)"
        var message = "HTTP \(status)"
        if let json = try? JSONCoding.decoder.decode(JSONValue.self, from: body), let err = json["error"] {
            code = err.string("code") ?? code
            message = err.string("message") ?? message
        }
        let text = "\(code): \(message)"
        switch status {
        case 401, 403: return .unauthorized(text)
        case 404: return .notFound(text)
        default: return .provider(text)
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

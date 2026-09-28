import Foundation

// Client für die Hostinger-API (https://developers.hostinger.com/api/<produkt>/v1). API-Token
// als `Authorization: Bearer`, keine Scopes. Fehler kommen als `{message, correlation_id}` bzw.
// bei 422 zusätzlich `errors{feld: [..]}` (ältere Endpunkte nennen `error`). Rate-Limit 90 Aufrufe
// pro Minute je IP: bei 429 wird `Retry-After` abgewartet und einmal wiederholt. Listen kommen
// entweder als `{data, meta{current_page, per_page, total}}` oder als nacktes Array; `list` liest
// beide Formen vollständig. VPS-Aktionen liefern ein Action-Objekt, auf das `waitForAction` bis
// `success` wartet (`error` wird zum Fehler). Aufrufe laufen seriell.

public actor HostingerClient {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias TokenProvider = @Sendable () async throws -> String

    public static let defaultBaseURL = URL(string: "https://developers.hostinger.com")!
    public static let pageSize = 100
    public static let rateLimitRetryCap: Duration = .seconds(30)

    private let baseURL: URL
    private let tokenProvider: TokenProvider
    private let transport: any HostingerTransport
    private let sleep: Sleep
    private let pollInterval: Duration
    private let pollTimeout: Duration
    private let now: @Sendable () -> Date

    public private(set) var rateLimitRemaining: Int?

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(tokenProvider: @escaping TokenProvider,
                transport: any HostingerTransport = URLSessionHostingerTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                baseURL: URL = HostingerClient.defaultBaseURL,
                pollInterval: Duration = .seconds(2),
                pollTimeout: Duration = .seconds(180),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.sleep = sleep
        self.baseURL = baseURL
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.now = now
    }

    public init(token: String, transport: any HostingerTransport = URLSessionHostingerTransport()) {
        self.init(tokenProvider: { token }, transport: transport)
    }

    // MARK: - Aufrufe

    @discardableResult
    public func request(_ method: String, _ path: String, query: [(String, String)] = [], body: JSONValue? = nil) async throws -> JSONValue {
        await acquire()
        defer { release() }
        return try await perform(method, path, query: query, body: body, retry: true)
    }

    public func get(_ path: String, query: [(String, String)] = []) async throws -> JSONValue { try await request("GET", path, query: query) }
    @discardableResult public func post(_ path: String, body: JSONValue? = nil) async throws -> JSONValue { try await request("POST", path, body: body) }
    @discardableResult public func put(_ path: String, body: JSONValue? = nil) async throws -> JSONValue { try await request("PUT", path, body: body) }
    @discardableResult public func patch(_ path: String, body: JSONValue) async throws -> JSONValue { try await request("PATCH", path, body: body) }
    @discardableResult public func delete(_ path: String, body: JSONValue? = nil) async throws -> JSONValue { try await request("DELETE", path, body: body) }

    /// Liest eine Liste vollständig: `{data, meta}` seitenweise über `page`/`per_page`, ein nacktes Array direkt.
    public func list(_ path: String, query: [(String, String)] = []) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var page = 1
        while true {
            let json = try await get(path, query: query + [("page", String(page)), ("per_page", String(Self.pageSize))])
            if let array = json.arrayValue { return array }
            let data = json.array("data")
            items += data
            let meta = json["meta"]
            let total = meta?.int("total")
            let perPage = meta?.int("per_page") ?? Self.pageSize
            if data.isEmpty || (total != nil && items.count >= total!) || data.count < perPage { break }
            page += 1
        }
        return items
    }

    /// Wartet, bis eine VPS-Action `success` erreicht; `error` wird zum Fehler, Timeout ebenfalls.
    @discardableResult
    public func waitForAction(_ action: JSONValue, vm: String) async throws -> JSONValue {
        var current = action
        let started = now()
        while true {
            switch current.string("state") {
            case "success": return current
            case "error": throw KastellanError.provider("Hostinger: Aktion \(current.string("name") ?? "?") auf Server \(vm) fehlgeschlagen")
            default:
                guard let id = current.int("id") else { throw KastellanError.provider("Hostinger: Action ohne ID in der Antwort") }
                let elapsed = Duration.seconds(now().timeIntervalSince(started))
                guard elapsed < pollTimeout else {
                    throw KastellanError.provider("Hostinger: Aktion \(current.string("name") ?? "?") (\(id)) nach \(Int(pollTimeout.components.seconds)) s nicht abgeschlossen; sie läuft bei Hostinger weiter")
                }
                try await sleep(pollInterval)
                current = try await get("/api/vps/v1/virtual-machines/\(vm)/actions/\(id)")
            }
        }
    }

    // MARK: - Intern

    private func perform(_ method: String, _ path: String, query: [(String, String)], body: JSONValue?, retry: Bool) async throws -> JSONValue {
        let request = try await buildRequest(method, path, query: query, body: body)
        let response = try await transport.send(request)
        if let remaining = response.header("X-RateLimit-Remaining").flatMap({ Int($0) }) { rateLimitRemaining = remaining }
        if response.status == 429, retry {
            try await sleep(retryDelay(for: response))
            return try await perform(method, path, query: query, body: body, retry: false)
        }
        guard (200..<300).contains(response.status) else {
            throw Self.error(status: response.status, body: response.body, method: method, path: path)
        }
        guard !response.body.isEmpty else { return .null }
        do {
            return try JSONCoding.decoder.decode(JSONValue.self, from: response.body)
        } catch {
            throw KastellanError.provider("Hostinger: Antwort ist kein JSON (\(method) \(path))")
        }
    }

    private func buildRequest(_ method: String, _ path: String, query: [(String, String)], body: JSONValue?) async throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw KastellanError.internal("Hostinger: ungültige Basis-URL")
        }
        components.path = baseURL.path + path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components.url else { throw KastellanError.invalidArgument("Hostinger: ungültiger Pfad \(path)") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Kastellan/\(KastellanCore.version)", forHTTPHeaderField: "User-Agent")
        if let body { request.httpBody = try JSONCoding.encoder.encode(body) }
        return request
    }

    private func retryDelay(for response: HostingerResponse) -> Duration {
        let cap = Double(Self.rateLimitRetryCap.components.seconds)
        let after = response.header("Retry-After").flatMap { Double($0) } ?? 5
        return .seconds(min(max(after, 1), cap))
    }

    /// `{message, correlation_id, errors{feld:[..]}}` bzw. `{error}` in `KastellanError`.
    static func error(status: Int, body: Data, method: String, path: String) -> KastellanError {
        var message = "HTTP \(status)"
        var details: [String] = []
        if let json = try? JSONCoding.decoder.decode(JSONValue.self, from: body) {
            message = json.string("message") ?? json.string("error") ?? message
            if let errors = json["errors"]?.objectValue {
                for (field, value) in errors.sorted(by: { $0.key < $1.key }) {
                    let texts = value.arrayValue?.compactMap(\.stringValue) ?? [value.stringValue].compactMap { $0 }
                    details.append("\(field): \(texts.joined(separator: ", "))")
                }
            }
            if let id = json.string("correlation_id") { details.append("correlation_id \(id)") }
        }
        let text = details.isEmpty ? message : "\(message) (\(details.joined(separator: "; ")))"
        switch status {
        case 400, 422: return .invalidArgument("\(method) \(path): \(text)")
        case 401, 403: return .unauthorized(text)
        case 404: return .notFound("\(method) \(path): \(text)")
        default: return .provider("\(method) \(path): \(text)")
        }
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

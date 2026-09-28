import Foundation

// Client für die Mittwald mStudio API v2 (https://api.mittwald.de/v2). Persönlicher API-Token als
// `Authorization: Bearer`. Fehler kommen als `{type, message}` bzw. `{type: ValidationError,
// validationErrors[{path, message}]}`. Rate-Limit über `X-RateLimit-*`, bei 429 einmal warten und
// wiederholen. Die API ist eventual consistent: schreibende Antworten tragen ein `etag`, das der
// Client beim nächsten lesenden Aufruf als `if-event-reached` mitschickt; antwortet die API mit
// 412 (Ereignis noch nicht verarbeitet), wird kurz gewartet und wiederholt. Listen werden über
// `limit`/`skip` und `X-Pagination-TotalCount` vollständig gelesen. Aufrufe laufen seriell.

public actor MittwaldClient {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias TokenProvider = @Sendable () async throws -> String

    public static let defaultBaseURL = URL(string: "https://api.mittwald.de/v2")!
    public static let pageSize = 100
    public static let rateLimitRetryCap: Duration = .seconds(10)
    /// Wiederholungen bei 412 (`if-event-reached` noch nicht erfüllt).
    public static let consistencyRetries = 3

    private let baseURL: URL
    private let tokenProvider: TokenProvider
    private let transport: any MittwaldTransport
    private let sleep: Sleep
    private let pollTimeout: Duration
    private let now: @Sendable () -> Date

    public private(set) var rateLimitRemaining: Int?
    /// etag der letzten schreibenden Antwort; wird bei lesenden Aufrufen als `if-event-reached` gesendet.
    public private(set) var lastEventTag: String?

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(tokenProvider: @escaping TokenProvider,
                transport: any MittwaldTransport = URLSessionMittwaldTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                baseURL: URL = MittwaldClient.defaultBaseURL,
                pollTimeout: Duration = .seconds(120),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.sleep = sleep
        self.baseURL = baseURL
        self.pollTimeout = pollTimeout
        self.now = now
    }

    public init(token: String, transport: any MittwaldTransport = URLSessionMittwaldTransport()) {
        self.init(tokenProvider: { token }, transport: transport)
    }

    // MARK: - Aufrufe

    public struct Result: Sendable {
        public let json: JSONValue
        public let status: Int
        public let headers: [String: String]
        public func header(_ name: String) -> String? { MittwaldResponse(status: status, headers: headers).header(name) }
    }

    @discardableResult
    public func request(_ method: String, _ path: String, query: [(String, String)] = [], body: JSONValue? = nil) async throws -> Result {
        await acquire()
        defer { release() }
        return try await perform(method, path, query: query, body: body, retry429: true, retry412: Self.consistencyRetries)
    }

    public func get(_ path: String, query: [(String, String)] = []) async throws -> JSONValue {
        try await request("GET", path, query: query).json
    }

    @discardableResult
    public func post(_ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        try await request("POST", path, body: body).json
    }

    @discardableResult
    public func put(_ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        try await request("PUT", path, body: body).json
    }

    @discardableResult
    public func patch(_ path: String, body: JSONValue) async throws -> JSONValue {
        try await request("PATCH", path, body: body).json
    }

    @discardableResult
    public func delete(_ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        try await request("DELETE", path, body: body).json
    }

    /// Liest alle Seiten einer Liste (`limit`/`skip`, `X-Pagination-TotalCount`).
    public func list(_ path: String, query: [(String, String)] = []) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var skip = 0
        while true {
            let r = try await request("GET", path, query: query + [("limit", String(Self.pageSize)), ("skip", String(skip))])
            let page = r.json.arrayValue ?? []
            items += page
            let total = r.header("X-Pagination-TotalCount").flatMap { Int($0) }
            skip += page.count
            if page.isEmpty || page.count < Self.pageSize || (total != nil && skip >= total!) { break }
        }
        return items
    }

    /// Pollt `fetch`, bis `ready` zutrifft; Backoff 1 s bis 8 s, sonst Timeout mit Hinweis.
    public func waitUntil(_ what: String, timeout: Duration? = nil, fetch: @Sendable () async throws -> JSONValue,
                          ready: @Sendable (JSONValue) -> Bool) async throws -> JSONValue {
        let limit = timeout ?? pollTimeout
        let started = now()
        var delay: Duration = .seconds(1)
        while true {
            let current = try await fetch()
            if ready(current) { return current }
            let elapsed = Duration.seconds(now().timeIntervalSince(started))
            guard elapsed < limit else {
                throw KastellanError.provider("Mittwald: \(what) nach \(Int(limit.components.seconds)) s noch nicht bereit; der Vorgang läuft bei Mittwald weiter")
            }
            try await sleep(delay)
            delay = min(delay * 2, .seconds(8))
        }
    }

    // MARK: - Intern

    private func perform(_ method: String, _ path: String, query: [(String, String)], body: JSONValue?, retry429: Bool, retry412: Int) async throws -> Result {
        let isRead = method == "GET"
        let request = try await buildRequest(method, path, query: query, body: body, eventTag: isRead ? lastEventTag : nil)
        let response = try await transport.send(request)
        if let remaining = response.header("X-RateLimit-Remaining").flatMap({ Int($0) }) { rateLimitRemaining = remaining }

        if response.status == 429, retry429 {
            try await sleep(retryDelay(for: response))
            return try await perform(method, path, query: query, body: body, retry429: false, retry412: retry412)
        }
        if response.status == 412, isRead, lastEventTag != nil, retry412 > 0 {
            try await sleep(.seconds(1))
            return try await perform(method, path, query: query, body: body, retry429: retry429, retry412: retry412 - 1)
        }
        guard (200..<300).contains(response.status) else {
            throw Self.error(status: response.status, body: response.body, method: method, path: path)
        }
        if !isRead, let tag = response.header("etag") ?? response.header("ETag") { lastEventTag = tag }
        let json: JSONValue
        if response.body.isEmpty {
            json = .null
        } else if let decoded = try? JSONCoding.decoder.decode(JSONValue.self, from: response.body) {
            json = decoded
        } else {
            throw KastellanError.provider("Mittwald: Antwort ist kein JSON (\(method) \(path))")
        }
        return Result(json: json, status: response.status, headers: response.headers)
    }

    private func buildRequest(_ method: String, _ path: String, query: [(String, String)], body: JSONValue?, eventTag: String?) async throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw KastellanError.internal("Mittwald: ungültige Basis-URL")
        }
        components.path = baseURL.path + path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components.url else { throw KastellanError.invalidArgument("Mittwald: ungültiger Pfad \(path)") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Kastellan/\(KastellanCore.version)", forHTTPHeaderField: "User-Agent")
        if let eventTag { request.setValue(eventTag, forHTTPHeaderField: "if-event-reached") }
        if let body {
            request.httpBody = try JSONCoding.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func retryDelay(for response: MittwaldResponse) -> Duration {
        let cap = Double(Self.rateLimitRetryCap.components.seconds)
        guard let reset = response.header("X-RateLimit-Reset").flatMap({ Double($0) }) else { return .seconds(1) }
        // Mittwald liefert Sekunden bis zum Reset; ein Epoch-Wert wird ebenfalls verstanden.
        let seconds = reset > 1_000_000_000 ? reset - now().timeIntervalSince1970 : reset
        return .seconds(min(max(seconds, 1), cap))
    }

    /// `{type, message}` und `ValidationError` mit Pfaden in `KastellanError`.
    static func error(status: Int, body: Data, method: String, path: String) -> KastellanError {
        var type = "http_\(status)"
        var message = "HTTP \(status)"
        if let json = try? JSONCoding.decoder.decode(JSONValue.self, from: body) {
            type = json.string("type") ?? type
            message = json.string("message") ?? message
            let details = json.array("validationErrors").compactMap { v -> String? in
                guard let m = v.string("message") else { return nil }
                return v.string("path").map { "\($0): \(m)" } ?? m
            }
            if !details.isEmpty { message += " (" + details.joined(separator: "; ") + ")" }
        }
        let text = "\(type): \(message)"
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

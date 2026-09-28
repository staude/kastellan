import Foundation

// Client für die hosting.de-API (https://www.hosting.de/api/). Methodenbasiert: jeder Aufruf ist
// ein POST auf `{base}/{service}/v1/json/{method}` mit JSON-Body, der `authToken` und optional
// `ownerAccountId` (Delegation an ein Unterkonto) trägt. Antworten haben `status` success,
// pending oder error, dazu `response`/`responses`, `errors[]`, `warnings[]` und `metadata`.
// Schreibvorgänge lassen Objekte kurz im Status `blocked` oder `creating`; `waitUntilActive`
// pollt mit Backoff, bis sie wieder `active` sind. Aufrufe pro Verbindung laufen seriell.

public actor HostingDeClient {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias TokenProvider = @Sendable () async throws -> String

    public static let defaultBaseURL = URL(string: "https://secure.hosting.de/api")!
    /// Seitengröße für `…Find`-Aufrufe.
    public static let pageSize = 100
    /// Erste Wartezeit beim Polling auf `active`, verdoppelt sich bis `pollCap`.
    public static let pollStart: Duration = .seconds(1)
    public static let pollCap: Duration = .seconds(8)

    private let baseURL: URL
    private let tokenProvider: TokenProvider
    private let ownerAccountID: String?
    private let transport: any HostingDeTransport
    private let sleep: Sleep
    private let pollTimeout: Duration
    private let now: @Sendable () -> Date

    /// Warnungen der letzten Antwort (automatisch korrigierte Eingaben wie hochgesetzte TTL).
    public private(set) var lastWarnings: [String] = []

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(tokenProvider: @escaping TokenProvider,
                ownerAccountID: String? = nil,
                transport: any HostingDeTransport = URLSessionHostingDeTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                baseURL: URL = HostingDeClient.defaultBaseURL,
                pollTimeout: Duration = .seconds(60),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokenProvider = tokenProvider
        self.ownerAccountID = ownerAccountID.flatMap { $0.isEmpty ? nil : $0 }
        self.transport = transport
        self.sleep = sleep
        self.baseURL = baseURL
        self.pollTimeout = pollTimeout
        self.now = now
    }

    public init(token: String, ownerAccountID: String? = nil,
                transport: any HostingDeTransport = URLSessionHostingDeTransport(),
                baseURL: URL = HostingDeClient.defaultBaseURL) {
        self.init(tokenProvider: { token }, ownerAccountID: ownerAccountID, transport: transport, baseURL: baseURL)
    }

    // MARK: - Aufrufe

    /// Ergebnis eines Aufrufs: Antwortobjekt und ob der Vorgang noch läuft (`pending`).
    public struct Result: Sendable {
        public let response: JSONValue
        public let pending: Bool
        public let warnings: [String]
    }

    /// Ruft `service/method` auf. Fehlerantworten (`status: error`, HTTP 4xx/5xx) werden zu
    /// `KastellanError`; `pending` wird nicht als Fehler behandelt.
    @discardableResult
    public func call(_ service: String, _ method: String, _ params: [String: JSONValue] = [:]) async throws -> Result {
        await acquire()
        defer { release() }
        return try await perform(service, method, params)
    }

    /// Wie `call`, liefert nur das Antwortobjekt.
    @discardableResult
    public func response(_ service: String, _ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await call(service, method, params).response
    }

    /// Liest alle Seiten einer `…Find`-Methode und liefert `data` zusammen. `sort` nur mit
    /// Feldnamen, die der jeweilige Dienst akzeptiert (sie sind je Dienst anders geschrieben);
    /// die Adapter sortieren deshalb lokal.
    public func findAll(_ service: String, _ method: String, filter: HostingDeFilter? = nil,
                        sort: (field: String, descending: Bool)? = nil, extra: [String: JSONValue] = [:]) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var page = 1
        while true {
            var params = extra
            params["limit"] = .int(Self.pageSize)
            params["page"] = .int(page)
            if let filter { params["filter"] = filter.json }
            if let sort { params["sort"] = .object(["field": .string(sort.field), "order": .string(sort.descending ? "DESC" : "ASC")]) }
            let r = try await response(service, method, params)
            items += r.array("data")
            let totalPages = r.int("totalPages") ?? 1
            guard page < totalPages else { break }
            page += 1
        }
        return items
    }

    /// Erste Seite mit begrenzter Anzahl, etwa für Health-Checks; liefert `data` und `totalEntries`.
    public func findPage(_ service: String, _ method: String, filter: HostingDeFilter? = nil, limit: Int = 1) async throws -> (data: [JSONValue], total: Int) {
        var params: [String: JSONValue] = ["limit": .int(limit), "page": .int(1)]
        if let filter { params["filter"] = filter.json }
        let r = try await response(service, method, params)
        return (r.array("data"), r.int("totalEntries") ?? r.array("data").count)
    }

    /// Wartet, bis das Objekt, das `fetch` liefert, den Status `active` hat (oder einen der
    /// zusätzlich erlaubten Zustände). `failed` wird zum Fehler, ebenso das Überschreiten des Timeouts.
    public func waitUntilActive(_ what: String, accepting: Set<String> = [], timeout: Duration? = nil,
                                fetch: @Sendable () async throws -> JSONValue?) async throws -> JSONValue {
        let pollTimeout = timeout ?? self.pollTimeout
        let started = now()
        var delay = Self.pollStart
        while true {
            let current = try await fetch()
            let status = current?.string("status") ?? ""
            if status == "active" || accepting.contains(status), let current { return current }
            if status == "failed" {
                throw KastellanError.provider("hosting.de: \(what) ist in den Zustand failed gelaufen")
            }
            let elapsed = Duration.seconds(now().timeIntervalSince(started))
            guard elapsed < pollTimeout else {
                throw KastellanError.provider("hosting.de: \(what) nach \(Int(pollTimeout.components.seconds)) s noch im Zustand \(status.isEmpty ? "unbekannt" : status); der Vorgang läuft bei hosting.de weiter")
            }
            try await sleep(delay)
            delay = min(delay * 2, Self.pollCap)
        }
    }

    // MARK: - Intern

    private func perform(_ service: String, _ method: String, _ params: [String: JSONValue]) async throws -> Result {
        let request = try await buildRequest(service, method, params)
        let response = try await transport.send(request)
        let json: JSONValue
        if response.body.isEmpty {
            json = .null
        } else if let decoded = try? JSONCoding.decoder.decode(JSONValue.self, from: response.body) {
            json = decoded
        } else {
            throw KastellanError.provider("hosting.de: Antwort ist kein JSON (\(service)/\(method), HTTP \(response.status))")
        }
        let warnings = json.array("warnings").compactMap { Self.describe($0) }
        lastWarnings = warnings

        let status = json.string("status") ?? ""
        if status == "error" || !(200..<300).contains(response.status) {
            throw Self.error(httpStatus: response.status, method: method, json: json)
        }
        let payload = json["response"] ?? json["responses"] ?? .null
        return Result(response: payload, pending: status == "pending", warnings: warnings)
    }

    private func buildRequest(_ service: String, _ method: String, _ params: [String: JSONValue]) async throws -> URLRequest {
        let url = baseURL.appendingPathComponent("\(service)/v1/json/\(method)")
        var body = params
        body["authToken"] = .string(try await tokenProvider())
        if let ownerAccountID { body["ownerAccountId"] = .string(ownerAccountID) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Kastellan/\(KastellanCore.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONCoding.encoder.encode(JSONValue.object(body))
        return request
    }

    /// `{code, text, contextPath, value}` als lesbarer Satz.
    static func describe(_ entry: JSONValue) -> String? {
        guard let text = entry.string("text") ?? entry.string("code") else { return nil }
        var s = text
        if let code = entry.int("code") ?? entry.string("code").flatMap(Int.init) { s = "\(code): \(s)" }
        if let path = entry.string("contextPath") { s += " (\(path))" }
        return s
    }

    /// Bildet `errors[]` auf `KastellanError` ab. Auth-Fehler werden an Text und Code erkannt.
    static func error(httpStatus: Int, method: String, json: JSONValue) -> KastellanError {
        let entries = json.array("errors").compactMap { describe($0) }
        let text = entries.isEmpty ? "HTTP \(httpStatus)" : entries.joined(separator: "; ")
        let lower = text.lowercased()
        if lower.contains("authtoken") || lower.contains("authentication") || lower.contains("not authorized")
            || lower.contains("permission") || lower.contains("nicht berechtigt") || httpStatus == 401 || httpStatus == 403 {
            return .unauthorized("\(method): \(text)")
        }
        if lower.contains("not found") || lower.contains("does not exist") || httpStatus == 404 {
            return .notFound("\(method): \(text)")
        }
        return .provider("\(method): \(text)")
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

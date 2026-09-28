import Foundation

// Client für die Cloudflare-REST-API v4. Kennt den Antwort-Envelope `{success, errors, result,
// result_info}`, blättert Listen durch (per_page=100), führt Aufrufe je Verbindung strikt
// nacheinander aus, drosselt auf 1200 Aufrufe je 5 Minuten und wiederholt bei HTTP 429 einmal
// nach `Retry-After`. Der Token wird nie geloggt und taucht in keiner Fehlermeldung auf.

/// Ein Eintrag aus `errors[]` der Cloudflare-Antwort.
public struct CloudflareAPIError: Decodable, Sendable, Equatable {
    public let code: Int
    public let message: String
}

/// Blätter-Informationen aus `result_info`.
struct CloudflareResultInfo: Decodable, Sendable {
    let page: Int?
    let perPage: Int?
    let totalPages: Int?
    let count: Int?
    let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case page, count
        case perPage = "per_page"
        case totalPages = "total_pages"
        case totalCount = "total_count"
    }
}

/// Der Envelope jeder Cloudflare-Antwort. `result` fehlt oder ist `null` bei Fehlern.
struct CloudflareEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let errors: [CloudflareAPIError]
    let result: T?
    let resultInfo: CloudflareResultInfo?

    enum CodingKeys: String, CodingKey {
        case success, errors, result
        case resultInfo = "result_info"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decodeIfPresent(Bool.self, forKey: .success) ?? false
        errors = try c.decodeIfPresent([CloudflareAPIError].self, forKey: .errors) ?? []
        result = try c.decodeIfPresent(T.self, forKey: .result)
        resultInfo = try c.decodeIfPresent(CloudflareResultInfo.self, forKey: .resultInfo)
    }

    /// `KastellanError.provider("<code>: <message>")`, mehrere Fehler mit `; ` verbunden.
    static func providerError(_ errors: [CloudflareAPIError], status: Int) -> KastellanError {
        guard !errors.isEmpty else { return .provider("Cloudflare: HTTP \(status) ohne Fehlerbeschreibung") }
        return .provider(errors.map { "\($0.code): \($0.message)" }.joined(separator: "; "))
    }
}

public actor CloudflareClient {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias TokenProvider = @Sendable () async throws -> String
    public typealias Clock = @Sendable () -> Date

    /// Cloudflare erlaubt 1200 Aufrufe je 5 Minuten pro Nutzer.
    public static let rateLimit = 1200
    public static let rateWindow: TimeInterval = 300
    /// Größte erlaubte Seite bei Listen-Endpunkten.
    public static let pageSize = 100
    /// Wartezeit nach HTTP 429 ohne `Retry-After`.
    public static let defaultRetryDelay: Duration = .seconds(2)

    private let tokenProvider: TokenProvider
    private let transport: any CloudflareTransport
    private let sleep: Sleep
    private let now: Clock
    private let rateLimit: Int

    /// Zeitpunkte der Aufrufe im aktuellen Fenster (für die Drosselung).
    private var callTimes: [Date] = []
    /// Zonenname → Zonen-ID, damit nicht jeder Aufruf erst `GET /zones?name=` braucht.
    private var zoneIDs: [String: String] = [:]

    // Serialisierung: Actor-Methoden sind an `await` reentrant, deshalb eine eigene Warteschlange.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(tokenProvider: @escaping TokenProvider,
                transport: any CloudflareTransport = URLSessionCloudflareTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                now: @escaping Clock = { Date() },
                rateLimit: Int = CloudflareClient.rateLimit) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.sleep = sleep
        self.now = now
        self.rateLimit = max(1, rateLimit)
    }

    public init(token: String,
                transport: any CloudflareTransport = URLSessionCloudflareTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                now: @escaping Clock = { Date() },
                rateLimit: Int = CloudflareClient.rateLimit) {
        self.init(tokenProvider: { token }, transport: transport, sleep: sleep, now: now, rateLimit: rateLimit)
    }

    // MARK: - Öffentliche Aufrufe

    public func get<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await request("GET", path, query: query)
    }

    public func post<T: Decodable & Sendable>(_ path: String, body: JSONValue) async throws -> T {
        try await request("POST", path, body: body)
    }

    public func put<T: Decodable & Sendable>(_ path: String, body: JSONValue) async throws -> T {
        try await request("PUT", path, body: body)
    }

    public func patch<T: Decodable & Sendable>(_ path: String, body: JSONValue) async throws -> T {
        try await request("PATCH", path, body: body)
    }

    public func delete<T: Decodable & Sendable>(_ path: String) async throws -> T {
        try await request("DELETE", path)
    }

    /// Ein Aufruf, liefert `result`. Fehlt `result` bei Erfolg, gibt es `provider`.
    public func request<T: Decodable & Sendable>(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue? = nil) async throws -> T {
        let envelope: CloudflareEnvelope<T> = try await call(method, path, query: query, body: body)
        guard let result = envelope.result else {
            throw KastellanError.provider("Cloudflare: \(method) \(path) lieferte kein result")
        }
        return result
    }

    /// Alle Seiten eines Listen-Endpunkts, `per_page=100`, `page` hochgezählt bis `total_pages`.
    public func list<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> [T] {
        var items: [T] = []
        var page = 1
        while true {
            var q = query
            q["per_page"] = String(Self.pageSize)
            q["page"] = String(page)
            let envelope: CloudflareEnvelope<[T]> = try await call("GET", path, query: q, body: nil)
            let batch = envelope.result ?? []
            items.append(contentsOf: batch)
            guard let info = envelope.resultInfo else { break }
            if let total = info.totalPages {
                if page >= total { break }
            } else if batch.count < Self.pageSize {
                break
            }
            page += 1
            if batch.isEmpty { break }
        }
        return items
    }

    /// Zonen-ID zu einem Zonennamen, gecacht je Client. Unbekannte Zone → `notFound`.
    public func zoneID(for zone: String) async throws -> String {
        let name = Self.zoneName(zone)
        if let id = zoneIDs[name] { return id }
        let zones: [CloudflareZone] = try await list("/zones", query: ["name": name])
        guard let match = zones.first(where: { $0.name.lowercased() == name }) ?? zones.first else {
            throw KastellanError.notFound("Zone \(name) bei Cloudflare")
        }
        zoneIDs[name] = match.id
        return match.id
    }

    /// Zonen aus einer Liste vormerken, damit `zoneID(for:)` sie kennt.
    public func remember(zones: [CloudflareZone]) {
        for zone in zones { zoneIDs[Self.zoneName(zone.name)] = zone.id }
    }

    /// Kanonischer Zonenname: kleingeschrieben, ohne Punkt am Ende.
    public static func zoneName(_ zone: String) -> String {
        var z = zone.trimmingCharacters(in: .whitespaces).lowercased()
        while z.hasSuffix(".") { z.removeLast() }
        return z
    }

    // MARK: - Intern

    func call<T: Decodable>(_ method: String, _ path: String, query: [String: String], body: JSONValue?) async throws -> CloudflareEnvelope<T> {
        await acquire()
        defer { release() }
        let token = try await tokenProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw KastellanError.unauthorized("Cloudflare-API-Token ist leer") }
        let headers = ["Authorization": "Bearer \(token)"]
        let bodyData = try body.map { try Self.encoder.encode($0) }
        return try await perform(method, path, query: query, body: bodyData, headers: headers, retryOn429: true)
    }

    private func perform<T: Decodable>(_ method: String, _ path: String, query: [String: String], body: Data?,
                                       headers: [String: String], retryOn429: Bool) async throws -> CloudflareEnvelope<T> {
        try await throttle()
        let (data, http) = try await transport.request(method: method, path: path, query: query, body: body, headers: headers)

        if http.statusCode == 429, retryOn429 {
            try await sleep(Self.retryDelay(from: http))
            return try await perform(method, path, query: query, body: body, headers: headers, retryOn429: false)
        }

        let envelope: CloudflareEnvelope<T>
        do {
            envelope = try Self.decoder.decode(CloudflareEnvelope<T>.self, from: data)
        } catch {
            guard (200..<300).contains(http.statusCode) else {
                throw KastellanError.provider("Cloudflare: HTTP \(http.statusCode) bei \(method) \(path)")
            }
            throw KastellanError.provider("Cloudflare: Antwort auf \(method) \(path) nicht lesbar (\(error.localizedDescription))")
        }
        guard envelope.success else {
            throw CloudflareEnvelope<T>.providerError(envelope.errors, status: http.statusCode)
        }
        return envelope
    }

    /// `Retry-After` in Sekunden, sonst Standardwartezeit.
    static func retryDelay(from http: HTTPURLResponse) -> Duration {
        if let raw = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return .seconds(seconds)
        }
        return defaultRetryDelay
    }

    /// Wartet, wenn im Fenster von fünf Minuten schon `rateLimit` Aufrufe liefen.
    private func throttle() async throws {
        let current = now()
        callTimes.removeAll { current.timeIntervalSince($0) >= Self.rateWindow }
        if callTimes.count >= rateLimit, let oldest = callTimes.first {
            let wait = Self.rateWindow - current.timeIntervalSince(oldest)
            if wait > 0 { try await sleep(.seconds(wait)) }
            let after = now()
            callTimes.removeAll { after.timeIntervalSince($0) >= Self.rateWindow }
        }
        callTimes.append(now())
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

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder = JSONDecoder()
}

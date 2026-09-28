import Foundation
@testable import KastellanCore

/// Lädt Cloudflare-Fixtures aus `Fixtures/cloudflare` (nach den Beispielen der API-Doku gebaut,
/// IDs erfunden, keine echten Antworten, weil kein Token zur Verfügung stand).
enum CloudflareFixtures {
    static let zoneID = "023e105f4ecef8ad9ca31a8372d0c353"

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/cloudflare") else {
            throw KastellanError.notFound("Fixture \(name).json")
        }
        return try Data(contentsOf: url)
    }

    /// Fixture als Stub-Antwort mit Status 200.
    static func response(_ name: String, status: Int = 200, headers: [String: String] = [:]) throws -> CloudflareStubResponse {
        CloudflareStubResponse(data: try data(name), status: status, headers: headers)
    }

    /// Erfolgs-Envelope um ein beliebiges `result`, mit optionalem `result_info`.
    static func envelope(_ result: JSONValue, page: Int? = nil, totalPages: Int? = nil, status: Int = 200) -> CloudflareStubResponse {
        var body: [String: JSONValue] = ["success": .bool(true), "errors": .array([]), "messages": .array([]), "result": result]
        if let page, let totalPages {
            body["result_info"] = .object(["page": .int(page), "per_page": .int(100), "total_pages": .int(totalPages)])
        }
        let data = try! JSONEncoder().encode(JSONValue.object(body))
        return CloudflareStubResponse(data: data, status: status, headers: [:])
    }

    /// Fehler-Envelope, wie Cloudflare ihn bei `success: false` liefert.
    static func failure(code: Int, message: String, status: Int = 400) -> CloudflareStubResponse {
        let body: JSONValue = .object([
            "success": .bool(false),
            "errors": .array([.object(["code": .int(code), "message": .string(message)])]),
            "messages": .array([]),
            "result": .null,
        ])
        return CloudflareStubResponse(data: try! JSONEncoder().encode(body), status: status, headers: [:])
    }

    /// Antwort ohne Body, etwa HTTP 429 mit `Retry-After`.
    static func empty(status: Int, headers: [String: String] = [:]) -> CloudflareStubResponse {
        CloudflareStubResponse(data: Data(), status: status, headers: headers)
    }

    /// Client mit Stub-Transport und aufgezeichneten Wartezeiten.
    static func client(_ responses: [CloudflareStubResponse], token: String = "cf-test-token", rateLimit: Int = CloudflareClient.rateLimit,
                       now: @escaping CloudflareClient.Clock = { Date() })
        -> (client: CloudflareClient, transport: CloudflareStubTransport, sleeps: CloudflareSleepRecorder) {
        let transport = CloudflareStubTransport(responses)
        let sleeps = CloudflareSleepRecorder()
        let client = CloudflareClient(token: token, transport: transport, sleep: { await sleeps.record($0) }, now: now, rateLimit: rateLimit)
        return (client, transport, sleeps)
    }

    /// Adapter mit Stub-Transport. `accountID` setzt `account_id` in den Verbindungseinstellungen.
    static func adapter(_ responses: [CloudflareStubResponse], connectionID: String = "conn-cf", accountID: String? = nil)
        -> (adapter: CloudflareAdapter, transport: CloudflareStubTransport) {
        let (client, transport, _) = client(responses)
        var settings: [String: String] = [:]
        if let accountID { settings["account_id"] = accountID }
        let connection = Connection(id: connectionID, profileID: "privat", provider: CloudflareAdapter.providerID,
                                    label: "Cloudflare Test", settings: settings)
        return (CloudflareAdapter(connection: connection, client: client), transport)
    }
}

struct CloudflareStubResponse: Sendable {
    let data: Data
    let status: Int
    let headers: [String: String]
}

/// Aufgezeichneter Request eines Stub-Transports.
struct CloudflareRecordedRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data?
    let headers: [String: String]

    /// Body als JSON-Baum.
    var json: JSONValue? {
        guard let body else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: body)
    }

    var object: [String: JSONValue] {
        if case .object(let o)? = json { return o }
        return [:]
    }

    var authorization: String? { headers["Authorization"] }
}

/// Transport, der vorbereitete Antworten in Reihenfolge liefert und Requests aufzeichnet.
actor CloudflareStubTransport: CloudflareTransport {
    private var responses: [CloudflareStubResponse]
    private(set) var requests: [CloudflareRecordedRequest] = []

    init(_ responses: [CloudflareStubResponse] = []) {
        self.responses = responses
    }

    func enqueue(_ response: CloudflareStubResponse) {
        responses.append(response)
    }

    func request(method: String, path: String, query: [String: String], body: Data?, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        requests.append(CloudflareRecordedRequest(method: method, path: path, query: query, body: body, headers: headers))
        guard !responses.isEmpty else {
            throw KastellanError.internal("Stub-Transport: keine Antwort mehr für \(method) \(path)")
        }
        let next = responses.removeFirst()
        let url = URLSessionCloudflareTransport.url(base: URLSessionCloudflareTransport.baseURL, path: path, query: query)
        let http = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
        return (next.data, http)
    }

    /// Pfade aller Aufrufe, etwa `GET /zones`.
    var calls: [String] { requests.map { "\($0.method) \($0.path)" } }
}

/// Zeichnet Wartezeiten auf, statt zu schlafen.
actor CloudflareSleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var intValue: Int? { if case .int(let i) = self { i } else { nil } }
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
}

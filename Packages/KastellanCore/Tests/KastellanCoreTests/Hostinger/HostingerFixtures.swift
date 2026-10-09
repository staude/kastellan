import Foundation
@testable import KastellanCore

/// Hostinger-Fixtures aus `Fixtures/hostinger` (nach der OpenAPI-Spec gebaut, nur Beispielwerte).
enum HostingerFixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/hostinger") else {
            throw KastellanError.notFound("Fixture \(name).json")
        }
        return try Data(contentsOf: url)
    }

    static let defaultHeaders = ["X-RateLimit-Limit": "90", "X-RateLimit-Remaining": "89", "Content-Type": "application/json"]

    static func ok(_ name: String, status: Int = 200) throws -> HostingerResponse {
        HostingerResponse(status: status, headers: defaultHeaders, body: try data(name))
    }

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HostingerResponse {
        HostingerResponse(status: status, headers: defaultHeaders.merging(headers) { _, n in n }, body: Data(text.utf8))
    }

    /// Envelope `{data, meta}`.
    static func page(_ items: [String], page: Int, perPage: Int, total: Int) -> HostingerResponse {
        json(#"{"data":[\#(items.joined(separator: ","))],"meta":{"current_page":\#(page),"per_page":\#(perPage),"total":\#(total)}}"#)
    }

    static func action(id: Int = 1, name: String = "start", state: String = "success") -> HostingerResponse {
        json(#"{"id":\#(id),"name":"\#(name)","state":"\#(state)","created_at":"2026-09-10T08:00:00Z","updated_at":"2026-09-10T08:00:05Z"}"#)
    }

    static func message(_ text: String = "ok") -> HostingerResponse { json(#"{"message":"\#(text)"}"#) }

    static func connection(id: String = "conn-hostinger", settings: [String: String] = [:]) -> Connection {
        Connection(id: id, profileID: "privat", provider: HostingerAdapter.providerID, label: "Hostinger Test", settings: settings)
    }

    static func adapter(_ responses: [HostingerResponse], settings: [String: String] = [:])
        -> (adapter: HostingerAdapter, transport: HostingerStubTransport, sleeps: HostingerSleepRecorder) {
        let (client, transport, sleeps) = HostingerClient.stubbed(responses)
        return (HostingerAdapter(connection: connection(settings: settings), client: client), transport, sleeps)
    }
}

struct HostingerRecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: JSONValue?
    var path: String { url.path }
    var query: [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }
}

actor HostingerStubTransport: HostingerTransport {
    private var responses: [HostingerResponse]
    private(set) var requests: [HostingerRecordedRequest] = []

    init(_ responses: [HostingerResponse] = []) { self.responses = responses }
    func enqueue(_ response: HostingerResponse) { responses.append(response) }

    /// Linux schreibt Header-Namen in Request-Feldern um; Tests lesen sie in Originalschreibweise und klein.
    static func caseInsensitive(_ headers: [String: String]) -> [String: String] {
        var out = headers
        for (k, v) in headers { out[k.lowercased()] = v }
        for (k, v) in headers where k.lowercased() == "authorization" { out["Authorization"] = v }
        for (k, v) in headers where k.lowercased() == "content-type" { out["Content-Type"] = v }
        return out
    }

    func send(_ request: URLRequest) async throws -> HostingerResponse {
        let body = request.httpBody.flatMap { try? JSONCoding.decoder.decode(JSONValue.self, from: $0) }
        requests.append(HostingerRecordedRequest(method: request.httpMethod ?? "GET", url: request.url!, headers: Self.caseInsensitive(request.allHTTPHeaderFields ?? [:]), body: body))
        guard !responses.isEmpty else {
            throw KastellanError.internal("Stub-Transport: keine Antwort mehr für \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
        }
        return responses.removeFirst()
    }
}

actor HostingerSleepRecorder {
    private(set) var durations: [Duration] = []
    let clock: HostingerFakeClock
    init(clock: HostingerFakeClock = HostingerFakeClock()) { self.clock = clock }
    func record(_ d: Duration) { durations.append(d); clock.advance(by: d) }
    var seconds: [Double] { durations.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } }
}

final class HostingerFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_757_142_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(by d: Duration) {
        lock.lock(); defer { lock.unlock() }
        time = time.addingTimeInterval(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }
}

extension HostingerClient {
    static func stubbed(_ responses: [HostingerResponse], token: String = "geheim", pollTimeout: Duration = .seconds(180))
        -> (client: HostingerClient, transport: HostingerStubTransport, sleeps: HostingerSleepRecorder) {
        let transport = HostingerStubTransport(responses)
        let clock = HostingerFakeClock()
        let sleeps = HostingerSleepRecorder(clock: clock)
        let client = HostingerClient(tokenProvider: { token }, transport: transport, sleep: { await sleeps.record($0) },
                                     pollTimeout: pollTimeout, now: { clock.now })
        return (client, transport, sleeps)
    }
}

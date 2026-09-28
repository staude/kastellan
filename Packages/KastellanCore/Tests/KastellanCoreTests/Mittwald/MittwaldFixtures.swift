import Foundation
@testable import KastellanCore

/// Mittwald-Fixtures aus `Fixtures/mittwald` (nach der OpenAPI-Spec gebaut, nur Beispielwerte).
enum MittwaldFixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/mittwald") else {
            throw KastellanError.notFound("Fixture \(name).json")
        }
        return try Data(contentsOf: url)
    }

    static let defaultHeaders = ["X-RateLimit-Limit": "3000", "X-RateLimit-Remaining": "2999", "X-RateLimit-Reset": "600", "Content-Type": "application/json"]

    static func ok(_ name: String, status: Int = 200, headers: [String: String] = [:]) throws -> MittwaldResponse {
        MittwaldResponse(status: status, headers: defaultHeaders.merging(headers) { _, n in n }, body: try data(name))
    }

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> MittwaldResponse {
        MittwaldResponse(status: status, headers: defaultHeaders.merging(headers) { _, n in n }, body: Data(text.utf8))
    }

    static func error(_ status: Int, type: String, message: String) -> MittwaldResponse {
        json(#"{"type":"\#(type)","message":"\#(message)"}"#, status: status)
    }

    static func empty(status: Int = 204, headers: [String: String] = [:]) -> MittwaldResponse {
        MittwaldResponse(status: status, headers: defaultHeaders.merging(headers) { _, n in n }, body: Data())
    }

    /// Listenseite mit Pagination-Headern.
    static func page(_ items: [String], total: Int) -> MittwaldResponse {
        json("[" + items.joined(separator: ",") + "]", headers: ["X-Pagination-TotalCount": String(total)])
    }

    static func connection(id: String = "conn-mittwald", settings: [String: String] = [:]) -> Connection {
        Connection(id: id, profileID: "privat", provider: MittwaldAdapter.providerID, label: "Mittwald Test", settings: settings)
    }

    static func adapter(_ responses: [MittwaldResponse], settings: [String: String] = [:])
        -> (adapter: MittwaldAdapter, transport: MittwaldStubTransport, sleeps: MittwaldSleepRecorder) {
        let (client, transport, sleeps) = MittwaldClient.stubbed(responses)
        return (MittwaldAdapter(connection: connection(settings: settings), client: client), transport, sleeps)
    }
}

struct MittwaldRecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: JSONValue?

    var path: String { url.path.hasPrefix("/v2") ? String(url.path.dropFirst(3)) : url.path }
    var query: [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }
}

actor MittwaldStubTransport: MittwaldTransport {
    private var responses: [MittwaldResponse]
    private(set) var requests: [MittwaldRecordedRequest] = []

    init(_ responses: [MittwaldResponse] = []) { self.responses = responses }

    func enqueue(_ response: MittwaldResponse) { responses.append(response) }

    func send(_ request: URLRequest) async throws -> MittwaldResponse {
        let body = request.httpBody.flatMap { try? JSONCoding.decoder.decode(JSONValue.self, from: $0) }
        requests.append(MittwaldRecordedRequest(method: request.httpMethod ?? "GET", url: request.url!,
                                                headers: request.allHTTPHeaderFields ?? [:], body: body))
        guard !responses.isEmpty else {
            throw KastellanError.internal("Stub-Transport: keine Antwort mehr für \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
        }
        return responses.removeFirst()
    }
}

actor MittwaldSleepRecorder {
    private(set) var durations: [Duration] = []
    let clock: MittwaldFakeClock
    init(clock: MittwaldFakeClock = MittwaldFakeClock()) { self.clock = clock }
    func record(_ d: Duration) { durations.append(d); clock.advance(by: d) }
    var seconds: [Double] { durations.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } }
}

final class MittwaldFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_757_142_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(by d: Duration) {
        lock.lock(); defer { lock.unlock() }
        time = time.addingTimeInterval(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }
}

extension MittwaldClient {
    static func stubbed(_ responses: [MittwaldResponse], token: String = "geheim", pollTimeout: Duration = .seconds(120))
        -> (client: MittwaldClient, transport: MittwaldStubTransport, sleeps: MittwaldSleepRecorder) {
        let transport = MittwaldStubTransport(responses)
        let clock = MittwaldFakeClock()
        let sleeps = MittwaldSleepRecorder(clock: clock)
        let client = MittwaldClient(tokenProvider: { token }, transport: transport, sleep: { await sleeps.record($0) },
                                    pollTimeout: pollTimeout, now: { clock.now })
        return (client, transport, sleeps)
    }
}

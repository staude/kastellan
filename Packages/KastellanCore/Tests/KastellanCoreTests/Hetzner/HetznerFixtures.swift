import Foundation
@testable import KastellanCore

/// Lädt Hetzner-Fixtures aus `Fixtures/hetzner` (nach der offiziellen API-Referenz gebaut,
/// keine Mitschnitte) und stellt Stub-Transport, Sleep-Recorder und Adapter bereit.
enum HetznerFixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/hetzner") else {
            throw KastellanError.notFound("Fixture \(name).json")
        }
        return try Data(contentsOf: url)
    }

    static let defaultHeaders = ["RateLimit-Limit": "3600", "RateLimit-Remaining": "3599", "Content-Type": "application/json"]

    /// 200 mit Fixture-Body.
    static func ok(_ name: String, status: Int = 200) throws -> HetznerResponse {
        HetznerResponse(status: status, headers: defaultHeaders, body: try data(name))
    }

    /// Antwort aus Inline-JSON.
    static func json(_ text: String, status: Int = 200, headers: [String: String] = defaultHeaders) -> HetznerResponse {
        HetznerResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    /// Fehlerhülle wie von der API.
    static func error(_ status: Int, code: String, message: String) -> HetznerResponse {
        json(#"{"error":{"code":"\#(code)","message":"\#(message)","details":null}}"#, status: status)
    }

    static func notFound(_ what: String = "resource") -> HetznerResponse {
        error(404, code: "not_found", message: "\(what) not found")
    }

    /// `{action: ...}` mit gewünschtem Status.
    static func action(id: Int = 1, command: String, status: String = "success", error: (code: String, message: String)? = nil) -> HetznerResponse {
        let err = error.map { #"{"code":"\#($0.code)","message":"\#($0.message)"}"# } ?? "null"
        return json(#"{"action":{"id":\#(id),"command":"\#(command)","status":"\#(status)","progress":0,"started":"2025-09-06T09:00:00Z","finished":null,"resources":[],"error":\#(err)}}"#)
    }

    static func empty(status: Int = 204) -> HetznerResponse {
        HetznerResponse(status: status, headers: defaultHeaders, body: Data())
    }

    static func connection(id: String = "conn-hetzner", project: String = "Test") -> Connection {
        Connection(id: id, profileID: "privat", provider: HetznerAdapter.providerID, label: "Hetzner Test", settings: ["project": project])
    }

    /// Adapter mit Stub-Transport und Sleep-Recorder.
    static func adapter(_ responses: [HetznerResponse], connectionID: String = "conn-hetzner")
        -> (adapter: HetznerAdapter, transport: HetznerStubTransport, sleeps: HetznerSleepRecorder) {
        let (client, transport, sleeps) = HetznerClient.stubbed(responses)
        return (HetznerAdapter(connection: connection(id: connectionID), client: client), transport, sleeps)
    }
}

/// Aufgezeichneter Request eines Stub-Transports.
struct HetznerRecordedRequest: Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let body: JSONValue?

    /// Pfad ohne `/v1`-Präfix, etwa `/zones/example.com/rrsets`.
    var path: String {
        let p = url.path
        return p.hasPrefix("/v1") ? String(p.dropFirst(3)) : p
    }

    var query: [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value ?? ""
        }
        return out
    }
}

/// Transport, der vorbereitete Antworten in Reihenfolge liefert und Requests aufzeichnet.
actor HetznerStubTransport: HetznerTransport {
    private var responses: [HetznerResponse]
    private(set) var requests: [HetznerRecordedRequest] = []

    init(_ responses: [HetznerResponse] = []) {
        self.responses = responses
    }

    func enqueue(_ response: HetznerResponse) {
        responses.append(response)
    }

    func send(_ request: URLRequest) async throws -> HetznerResponse {
        let body = request.httpBody.flatMap { try? JSONCoding.decoder.decode(JSONValue.self, from: $0) }
        requests.append(HetznerRecordedRequest(method: request.httpMethod ?? "GET", url: request.url!,
                                               authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        guard !responses.isEmpty else {
            throw KastellanError.internal("Stub-Transport: keine Antwort mehr für \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
        }
        return responses.removeFirst()
    }
}

/// Zeichnet Wartezeiten auf und lässt eine simulierte Uhr weiterlaufen, statt zu schlafen.
actor HetznerSleepRecorder {
    private(set) var durations: [Duration] = []
    let clock: HetznerFakeClock

    init(clock: HetznerFakeClock = HetznerFakeClock()) {
        self.clock = clock
    }

    func record(_ d: Duration) {
        durations.append(d)
        clock.advance(by: d)
    }

    var seconds: [Double] {
        durations.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
    }
}

/// Simulierte Zeit für Timeout-Tests; synchron lesbar, weil `HetznerClient.now` synchron ist.
final class HetznerFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Date

    init(start: Date = Date(timeIntervalSince1970: 1_757_142_000)) {
        time = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return time
    }

    func advance(by d: Duration) {
        lock.lock(); defer { lock.unlock() }
        time = time.addingTimeInterval(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }
}

extension HetznerClient {
    /// Client mit Stub-Transport, Sleep-Recorder und simulierter Uhr für Tests.
    static func stubbed(_ responses: [HetznerResponse], token: String = "geheim", pollTimeout: Duration = .seconds(60))
        -> (client: HetznerClient, transport: HetznerStubTransport, sleeps: HetznerSleepRecorder) {
        let transport = HetznerStubTransport(responses)
        let clock = HetznerFakeClock()
        let sleeps = HetznerSleepRecorder(clock: clock)
        let client = HetznerClient(tokenProvider: { token }, transport: transport, sleep: { await sleeps.record($0) },
                                   pollTimeout: pollTimeout, now: { clock.now })
        return (client, transport, sleeps)
    }
}

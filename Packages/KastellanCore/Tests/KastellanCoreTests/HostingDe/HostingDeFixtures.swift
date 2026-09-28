import Foundation
@testable import KastellanCore

/// Lädt hosting.de-Fixtures aus `Fixtures/hostingde` (nach der API-Referenz gebaut, keine
/// Mitschnitte, nur Beispielwerte) und stellt Stub-Transport, Sleep-Recorder und Adapter bereit.
enum HostingDeFixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/hostingde") else {
            throw KastellanError.notFound("Fixture \(name).json")
        }
        return try Data(contentsOf: url)
    }

    static func ok(_ name: String, status: Int = 200) throws -> HostingDeResponse {
        HostingDeResponse(status: status, body: try data(name))
    }

    static func json(_ text: String, status: Int = 200) -> HostingDeResponse {
        HostingDeResponse(status: status, body: Data(text.utf8))
    }

    /// Antwort einer Find-Methode mit `data` und Seitenangaben.
    static func page(_ items: [String], page: Int, totalPages: Int, totalEntries: Int? = nil) -> HostingDeResponse {
        json(#"{"status":"success","errors":[],"warnings":[],"metadata":{"clientTransactionId":"","serverTransactionId":"t"},"response":{"data":[\#(items.joined(separator: ","))],"limit":100,"page":\#(page),"totalPages":\#(totalPages),"totalEntries":\#(totalEntries ?? items.count),"type":"FindResult"}}"#)
    }

    /// Einzelobjekt mit Status, etwa für Polling.
    static func object(status: String, id: String = "obj-1", type: String = "ZoneConfig") -> HostingDeResponse {
        json(#"{"status":"success","errors":[],"warnings":[],"metadata":{},"response":{"id":"\#(id)","status":"\#(status)","name":"example.com","type":"\#(type)"}}"#)
    }

    static func connection(id: String = "conn-hostingde", settings: [String: String] = [:]) -> Connection {
        Connection(id: id, profileID: "privat", provider: HostingDeAdapter.providerID, label: "hosting.de Test", settings: settings)
    }

    static func adapter(_ responses: [HostingDeResponse], connectionID: String = "conn-hostingde", settings: [String: String] = [:])
        -> (adapter: HostingDeAdapter, transport: HostingDeStubTransport, sleeps: HostingDeSleepRecorder) {
        let (client, transport, sleeps) = HostingDeClient.stubbed(responses, ownerAccountID: settings["account_id"])
        return (HostingDeAdapter(connection: connection(id: connectionID, settings: settings), client: client), transport, sleeps)
    }
}

struct HostingDeRecordedRequest: Sendable {
    let url: URL
    let body: JSONValue

    /// `service/method`, etwa `dns/zoneConfigsFind`.
    var method: String {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let api = parts.firstIndex(of: "api"), parts.count > api + 4 else { return url.path }
        return "\(parts[api + 1])/\(parts[api + 4])"
    }

    func param(_ key: String) -> JSONValue? { body[key] }
}

actor HostingDeStubTransport: HostingDeTransport {
    private var responses: [HostingDeResponse]
    private(set) var requests: [HostingDeRecordedRequest] = []

    init(_ responses: [HostingDeResponse] = []) {
        self.responses = responses
    }

    func enqueue(_ response: HostingDeResponse) { responses.append(response) }

    func send(_ request: URLRequest) async throws -> HostingDeResponse {
        let body = request.httpBody.flatMap { try? JSONCoding.decoder.decode(JSONValue.self, from: $0) } ?? .null
        requests.append(HostingDeRecordedRequest(url: request.url!, body: body))
        guard !responses.isEmpty else {
            throw KastellanError.internal("Stub-Transport: keine Antwort mehr für \(request.url?.path ?? "?")")
        }
        return responses.removeFirst()
    }
}

actor HostingDeSleepRecorder {
    private(set) var durations: [Duration] = []
    let clock: HostingDeFakeClock

    init(clock: HostingDeFakeClock = HostingDeFakeClock()) { self.clock = clock }

    func record(_ d: Duration) {
        durations.append(d)
        clock.advance(by: d)
    }

    var seconds: [Double] { durations.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } }
}

final class HostingDeFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_757_142_000)

    var now: Date { lock.lock(); defer { lock.unlock() }; return time }

    func advance(by d: Duration) {
        lock.lock(); defer { lock.unlock() }
        time = time.addingTimeInterval(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }
}

extension HostingDeClient {
    static func stubbed(_ responses: [HostingDeResponse], token: String = "geheim", ownerAccountID: String? = nil,
                        pollTimeout: Duration = .seconds(60))
        -> (client: HostingDeClient, transport: HostingDeStubTransport, sleeps: HostingDeSleepRecorder) {
        let transport = HostingDeStubTransport(responses)
        let clock = HostingDeFakeClock()
        let sleeps = HostingDeSleepRecorder(clock: clock)
        let client = HostingDeClient(tokenProvider: { token }, ownerAccountID: ownerAccountID, transport: transport,
                                     sleep: { await sleeps.record($0) }, pollTimeout: pollTimeout, now: { clock.now })
        return (client, transport, sleeps)
    }
}

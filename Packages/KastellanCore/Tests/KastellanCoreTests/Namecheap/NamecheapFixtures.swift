import Foundation
@testable import KastellanCore

/// Namecheap-Fixtures aus `Fixtures/namecheap` (mit `tools/namecheap-probe.py` aus echten Antworten
/// anonymisiert) und kleine XML-Bausteine für Fälle, die das Konto nicht hergibt.
enum NamecheapFixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/namecheap") else {
            throw KastellanError.notFound("Fixture \(name).xml")
        }
        return try Data(contentsOf: url)
    }

    static func ok(_ name: String) throws -> NamecheapResponse {
        NamecheapResponse(status: 200, body: try data(name))
    }

    /// Erfolgsantwort mit beliebigem Inhalt in `CommandResponse`.
    static func response(_ command: String, _ inner: String) -> NamecheapResponse {
        NamecheapResponse(status: 200, body: Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <ApiResponse Status="OK" xmlns="http://api.namecheap.com/xml.response"><Errors /><Warnings /><RequestedCommand>\(command.lowercased())</RequestedCommand><CommandResponse Type="\(command)">\(inner)</CommandResponse><Server>TEST</Server><GMTTimeDifference>--4:00</GMTTimeDifference><ExecutionTime>0.01</ExecutionTime></ApiResponse>
        """.utf8))
    }

    static func error(_ number: String, _ text: String) -> NamecheapResponse {
        NamecheapResponse(status: 200, body: Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <ApiResponse Status="ERROR" xmlns="http://api.namecheap.com/xml.response"><Errors><Error Number="\(number)">\(text)</Error></Errors><Warnings /><RequestedCommand>x</RequestedCommand><CommandResponse /><Server>TEST</Server></ApiResponse>
        """.utf8))
    }

    static let credentials = NamecheapClient.Credentials(apiUser: "apiuser", apiKey: "geheim", clientIP: "192.0.2.1")

    static func connection(id: String = "conn-namecheap", settings: [String: String] = ["api_user": "apiuser", "client_ip": "192.0.2.1"]) -> Connection {
        Connection(id: id, profileID: "privat", provider: NamecheapAdapter.providerID, label: "Namecheap Test", settings: settings)
    }

    static func adapter(_ responses: [NamecheapResponse]) -> (adapter: NamecheapAdapter, transport: NamecheapStubTransport) {
        let (client, transport, _) = NamecheapClient.stubbed(responses)
        return (NamecheapAdapter(connection: connection(), client: client), transport)
    }
}

struct NamecheapRecordedRequest: Sendable {
    let url: URL
    let method: String
    let form: [(String, String)]
    var command: String { value("Command") ?? "" }
    func value(_ key: String) -> String? { form.first { $0.0 == key }?.1 }
    func values(prefix: String) -> [String: String] {
        Dictionary(form.filter { $0.0.hasPrefix(prefix) }.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    }
}

actor NamecheapStubTransport: NamecheapTransport {
    private var responses: [NamecheapResponse]
    private(set) var requests: [NamecheapRecordedRequest] = []

    init(_ responses: [NamecheapResponse] = []) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> NamecheapResponse {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let form: [(String, String)] = body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
        requests.append(NamecheapRecordedRequest(url: request.url!, method: request.httpMethod ?? "GET", form: form))
        guard !responses.isEmpty else {
            throw KastellanError.internal("Stub-Transport: keine Antwort mehr für \(form.first { $0.0 == "Command" }?.1 ?? "?")")
        }
        return responses.removeFirst()
    }
}

final class NamecheapFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(by seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; time = time.addingTimeInterval(seconds) }
}

actor NamecheapSleepRecorder {
    private(set) var seconds: [Double] = []
    let clock: NamecheapFakeClock
    init(clock: NamecheapFakeClock) { self.clock = clock }
    func record(_ d: Duration) {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        seconds.append(s); clock.advance(by: s)
    }
}

extension NamecheapClient {
    static func stubbed(_ responses: [NamecheapResponse], sandbox: Bool = false, clock: NamecheapFakeClock = NamecheapFakeClock())
        -> (client: NamecheapClient, transport: NamecheapStubTransport, sleeps: NamecheapSleepRecorder) {
        let transport = NamecheapStubTransport(responses)
        let sleeps = NamecheapSleepRecorder(clock: clock)
        let client = NamecheapClient(credentials: { NamecheapFixtures.credentials }, sandbox: sandbox, transport: transport,
                                     sleep: { await sleeps.record($0) }, now: { clock.now })
        return (client, transport, sleeps)
    }
}

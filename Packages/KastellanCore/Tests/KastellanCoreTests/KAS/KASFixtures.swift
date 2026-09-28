import Foundation
@testable import KastellanCore

/// Lädt KAS-Fixtures aus `Fixtures/kas` (echte Antworten, auf zwei Einträge gekürzt, Tokens maskiert).
enum KASFixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/kas") else {
            throw KastellanError.notFound("Fixture \(name).xml")
        }
        return try Data(contentsOf: url)
    }

    static func response(_ action: String) throws -> Data {
        try data("\(action)-response")
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    /// Envelope mit einem Fault, etwa für `flood_protection` oder eine abgelaufene Session.
    static func fault(_ faultstring: String, detail: String = "") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/"><SOAP-ENV:Body><SOAP-ENV:Fault><faultcode>SOAP-ENV:Server</faultcode><faultstring>\(faultstring)</faultstring><faultactor>KasApi</faultactor><detail>\(detail)</detail></SOAP-ENV:Fault></SOAP-ENV:Body></SOAP-ENV:Envelope>
        """.utf8)
    }

    /// Minimale `KasApi`-Antwort mit skalarem `ReturnInfo`, etwa für `add_mailaccount`.
    static func scalarResponse(_ action: String, returnInfo: String, floodDelay: String = "0.5") -> Data {
        response(action, returnInfoXML: "<value xsi:type=\"xsd:string\">\(escape(returnInfo))</value>", floodDelay: floodDelay)
    }

    /// `KasApi`-Antwort mit `ReturnInfo` als Array von Maps (leeres Array bei `[]`).
    /// `nil`-Werte werden zu `xsi:nil`, damit auch Sonderfälle ohne echtes Fixture testbar sind.
    static func mapArrayResponse(_ action: String, items: [[String: String?]], floodDelay: String = "0.5") -> Data {
        let body = items.map { item -> String in
            let fields = item.keys.sorted().map { key -> String in
                let value = item[key]! == nil
                    ? "<value xsi:nil=\"true\"/>"
                    : "<value xsi:type=\"xsd:string\">\(escape(item[key]!!))</value>"
                return "<item><key xsi:type=\"xsd:string\">\(key)</key>\(value)</item>"
            }.joined()
            return "<item xsi:type=\"ns2:Map\">\(fields)</item>"
        }.joined()
        let xml = "<value SOAP-ENC:arrayType=\"ns2:Map[\(items.count)]\" xsi:type=\"SOAP-ENC:Array\">\(body)</value>"
        return response(action, returnInfoXML: xml, floodDelay: floodDelay)
    }

    private static func response(_ action: String, returnInfoXML: String, floodDelay: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="https://kasapi.kasserver.com/soap/KasApi.php" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:ns2="http://xml.apache.org/xml-soap" xmlns:SOAP-ENC="http://schemas.xmlsoap.org/soap/encoding/" SOAP-ENV:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><SOAP-ENV:Body><ns1:KasApiResponse><return xsi:type="ns2:Map"><item><key xsi:type="xsd:string">Request</key><value xsi:type="ns2:Map"><item><key xsi:type="xsd:string">KasRequestType</key><value xsi:type="xsd:string">\(action)</value></item></value></item><item><key xsi:type="xsd:string">Response</key><value xsi:type="ns2:Map"><item><key xsi:type="xsd:string">KasFloodDelay</key><value xsi:type="xsd:float">\(floodDelay)</value></item><item><key xsi:type="xsd:string">ReturnString</key><value xsi:type="xsd:string">TRUE</value></item><item><key xsi:type="xsd:string">ReturnInfo</key>\(returnInfoXML)</item></value></item></return></ns1:KasApiResponse></SOAP-ENV:Body></SOAP-ENV:Envelope>
        """.utf8)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Adapter mit Stub-Transport. Die erste Antwort ist immer die Anmeldung.
    static func adapter(_ responses: [Data], connectionID: String = "conn-kas", login: String = "w00abcde") throws
        -> (adapter: KASAdapter, transport: KASStubTransport) {
        let (client, transport, _) = KASClient.stubbed([try response("kasauth")] + responses, login: login)
        let connection = Connection(id: connectionID, profileID: "privat", provider: KASAdapter.providerID,
                                    label: "All-Inkl Test", settings: ["kas_login": login])
        return (KASAdapter(connection: connection, client: client), transport)
    }
}

/// Aufgezeichneter SOAP-Request eines Stub-Transports.
struct KASRecordedRequest: Sendable {
    let url: URL
    let soapAction: String
    let body: String

    /// JSON aus `<Params>` als Dictionary.
    var params: [String: Any] {
        guard let start = body.range(of: "<Params xsi:type=\"xsd:string\">"),
              let end = body.range(of: "</Params>") else { return [:] }
        let escaped = String(body[start.upperBound..<end.lowerBound])
        let json = escaped.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    var action: String? { params["kas_action"] as? String }
    var requestParams: [String: String] { params["KasRequestParams"] as? [String: String] ?? [:] }
    var isAuth: Bool { url == KASEnvelope.authURL }
}

/// Transport, der vorbereitete Antworten in Reihenfolge liefert und Requests aufzeichnet.
actor KASStubTransport: KASTransport {
    private var responses: [Data]
    private(set) var requests: [KASRecordedRequest] = []

    init(_ responses: [Data] = []) {
        self.responses = responses
    }

    func enqueue(_ data: Data) {
        responses.append(data)
    }

    func post(url: URL, soapAction: String, body: Data) async throws -> Data {
        requests.append(KASRecordedRequest(url: url, soapAction: soapAction, body: String(decoding: body, as: UTF8.self)))
        guard !responses.isEmpty else {
            throw KastellanError.internal("Stub-Transport: keine Antwort mehr für \(soapAction)")
        }
        return responses.removeFirst()
    }
}

/// Zeichnet Wartezeiten auf, statt zu schlafen.
actor KASSleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ d: Duration) {
        durations.append(d)
    }

    var seconds: [Double] {
        durations.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
    }
}

extension KASClient {
    /// Client mit Stub-Transport und Sleep-Recorder für Tests.
    static func stubbed(_ responses: [Data], login: String = "w00abcde", password: String = "geheim")
        -> (client: KASClient, transport: KASStubTransport, sleeps: KASSleepRecorder) {
        let transport = KASStubTransport(responses)
        let sleeps = KASSleepRecorder()
        let client = KASClient(login: login, password: password, transport: transport, sleep: { await sleeps.record($0) })
        return (client, transport, sleeps)
    }
}

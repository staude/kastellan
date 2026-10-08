import Foundation

// Client für die Namecheap-API (https://api.namecheap.com/xml.response, Sandbox unter
// api.sandbox.namecheap.com). Ein Endpunkt, der Befehl steht im Parameter `Command`, jede Anfrage
// trägt `ApiUser`, `ApiKey`, `UserName` und `ClientIp`. Kastellan schickt immer POST als Formular,
// weil `setHosts` mit vielen Records sonst an der URL-Länge scheitert. Antworten sind XML mit
// `Status="OK|ERROR"`, Fehler stehen als `<Error Number="…">` darin, auch bei HTTP 200.
//
// `ClientIp` prüft Namecheap nur auf das Format (1011105); maßgeblich ist die Absenderadresse, die
// im Panel unter Profile → Tools → Namecheap API Access freigegeben sein muss. Limits: 50 Aufrufe
// pro Minute, 700 pro Stunde, 8000 pro Tag je Key. Der Client zählt selbst, wartet bei Minute und
// Stunde und bricht beim Tageslimit mit Uhrzeit ab. Aufrufe laufen seriell.

public actor NamecheapClient {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias CredentialsProvider = @Sendable () async throws -> Credentials

    public struct Credentials: Sendable, Equatable {
        public var apiUser: String
        public var apiKey: String
        public var userName: String
        public var clientIP: String

        public init(apiUser: String, apiKey: String, userName: String? = nil, clientIP: String) {
            self.apiUser = apiUser; self.apiKey = apiKey
            self.userName = (userName?.isEmpty == false ? userName! : apiUser); self.clientIP = clientIP
        }
    }

    public static let productionURL = URL(string: "https://api.namecheap.com/xml.response")!
    public static let sandboxURL = URL(string: "https://api.sandbox.namecheap.com/xml.response")!
    public static let pageSize = 100
    /// Fenster und Grenzen laut Namecheap-FAQ.
    public static let limits: [(window: TimeInterval, max: Int, label: String)] = [(60, 50, "Minute"), (3600, 700, "Stunde"), (86400, 8000, "Tag")]

    private let endpoint: URL
    private let credentials: CredentialsProvider
    private let transport: any NamecheapTransport
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    /// Ermittelt bei Fehler 1011150 die öffentliche IPv4 für die Meldung; nil schaltet das ab.
    private let publicIP: (@Sendable () async -> String?)?

    private var sent: [Date] = []
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public private(set) var lastWarnings: [String] = []

    public init(credentials: @escaping CredentialsProvider,
                sandbox: Bool = false,
                transport: any NamecheapTransport = URLSessionNamecheapTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = { Date() },
                publicIP: (@Sendable () async -> String?)? = nil) {
        self.credentials = credentials
        self.publicIP = publicIP
        self.endpoint = sandbox ? Self.sandboxURL : Self.productionURL
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Aufrufe

    /// Führt einen Befehl aus und liefert das Element `CommandResponse`.
    @discardableResult
    public func call(_ command: String, _ parameters: [(String, String)] = []) async throws -> NamecheapXMLElement {
        await acquire()
        defer { release() }
        try await throttle()
        let creds = try await credentials()
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Kastellan/\(KastellanCore.version)", forHTTPHeaderField: "User-Agent")
        let form: [(String, String)] = [("ApiUser", creds.apiUser), ("ApiKey", creds.apiKey), ("UserName", creds.userName),
                                        ("ClientIp", creds.clientIP), ("Command", command)] + parameters
        request.httpBody = Data(Self.formEncode(form).utf8)
        sent.append(now())
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else {
            throw KastellanError.provider("Namecheap \(command): HTTP \(response.status)")
        }
        let root = try NamecheapXMLElement.parse(response.body)
        lastWarnings = root.child("Warnings")?.children.map(\.text).filter { !$0.isEmpty } ?? []
        if root["Status"]?.uppercased() != "OK" {
            let errors = root.child("Errors")?.children("Error") ?? []
            guard let first = errors.first else { throw KastellanError.provider("Namecheap \(command): Status \(root["Status"] ?? "?") ohne Fehlertext") }
            let number = first["Number"] ?? ""
            if number == "1011150", let publicIP, let ip = await publicIP() {
                throw KastellanError.unauthorized("Namecheap: Die öffentliche IPv4 dieses Macs ist \(ip) und steht nicht auf der Freigabeliste. Im Namecheap-Panel unter Profile → Tools → Namecheap API Access eintragen. \(first.text) (\(number))")
            }
            throw Self.error(number: number, text: first.text, command: command)
        }
        guard let commandResponse = root.child("CommandResponse") else {
            throw KastellanError.provider("Namecheap \(command): Antwort ohne CommandResponse")
        }
        return commandResponse
    }

    /// Liest eine seitenweise Liste vollständig. `item` ist der Elementname der Einträge (etwa `Domain`).
    public func list(_ command: String, item: String, _ parameters: [(String, String)] = []) async throws -> [NamecheapXMLElement] {
        var items: [NamecheapXMLElement] = []
        var page = 1
        while true {
            let response = try await call(command, parameters + [("PageSize", String(Self.pageSize)), ("Page", String(page))])
            let batch = response.descendants(item)
            items += batch
            let total = response.firstDescendant("Paging")?.child("TotalItems").flatMap { Int($0.text) }
            if batch.isEmpty || total == nil || items.count >= total! || batch.count < Self.pageSize { break }
            page += 1
        }
        return items
    }

    // MARK: - Hilfen

    /// Registrierte Domains sind immer SLD.TLD, auch bei mehrteiligen TLDs wie `co.uk`.
    public static func split(_ domain: String) throws -> (sld: String, tld: String) {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard let dot = d.firstIndex(of: "."), dot != d.startIndex, d.index(after: dot) != d.endIndex else {
            throw KastellanError.invalidArgument("Namecheap: \(domain) ist kein Domainname")
        }
        return (String(d[..<dot]), String(d[d.index(after: dot)...]))
    }

    static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    /// Fehlernummern aus der Namecheap-Doku und den Probe-Läufen in `KastellanError`.
    static func error(number: String, text: String, command: String) -> KastellanError {
        let detail = "\(text) (\(number))"
        switch number {
        case "1011102", "1010101", "1010102":
            return .unauthorized("Namecheap: API-Key ungültig oder API-Zugang nicht freigeschaltet. \(detail)")
        case "1011150":
            return .unauthorized("Namecheap: Diese IP ist nicht freigegeben. Im Namecheap-Panel unter Profile → Tools → Namecheap API Access die öffentliche IPv4 dieses Macs eintragen. \(detail)")
        case "1011105":
            return .invalidArgument("Namecheap: Die Einstellung Client-IP ist keine gültige IPv4-Adresse. \(detail)")
        case "2030288":
            return .unsupported("Namecheap: Die Domain nutzt nicht die Namecheap-Nameserver, DNS und Weiterleitungen lassen sich hier nicht ändern. \(detail)")
        case "2015280":
            return .unsupported("Namecheap: Für diese TLD gibt es keinen Registrar-Lock. \(detail)")
        case "2019166", "2016166":
            return .notFound("Namecheap \(command): \(detail)")
        default:
            return .provider("Namecheap \(command): \(detail)")
        }
    }

    // MARK: - Drosselung

    private func throttle() async throws {
        while true {
            let current = now()
            sent.removeAll { current.timeIntervalSince($0) >= 86400 }
            var wait: TimeInterval = 0
            for limit in Self.limits {
                let inWindow = sent.filter { current.timeIntervalSince($0) < limit.window }
                guard inWindow.count >= limit.max, let oldest = inWindow.min() else { continue }
                let until = oldest.addingTimeInterval(limit.window)
                if limit.window >= 86400 {
                    let f = DateFormatter()
                    f.dateFormat = "dd.MM. HH:mm"
                    throw KastellanError.provider("Namecheap: Tageslimit von \(limit.max) Aufrufen erreicht, wieder möglich ab \(f.string(from: until))")
                }
                wait = max(wait, until.timeIntervalSince(current))
            }
            guard wait > 0 else { return }
            try await sleep(.milliseconds(Int((wait * 1000).rounded(.up))))
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

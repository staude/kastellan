import Foundation

// Adapter für Namecheap (Registrar mit eigenem DNS und Mail-Weiterleitung, XML-API). Ein API-Key
// je Konto, ohne Rechte: der Key darf alles inklusive Domain-Kauf. Kastellan bietet nur Lesen,
// DNS, Weiterleitungen und Domain-Einstellungen an; Kauf, Verlängerung, Transfer, Kontakte und
// SSL-Bestellungen bleiben außen vor. Die Ressourcen-Protokolle folgen in eigenen Dateien.

public struct NamecheapAdapter: ProviderAdapter {
    public static let providerID = "namecheap"
    public static let displayName = "Namecheap"
    public static let settingKeys = [
        SettingKey("api_user", label: "API-Benutzer", placeholder: "Namecheap-Benutzername"),
        SettingKey("username", label: "Konto", placeholder: "leer = API-Benutzer"),
        SettingKey("client_ip", label: "Client-IP", placeholder: "öffentliche IPv4, im Panel freigegeben"),
        SettingKey("sandbox", label: "Sandbox", placeholder: "leer = Produktion, ja = api.sandbox.namecheap.com"),
    ]
    public static let secretKeys = [SettingKey("api_key", label: "API-Key", placeholder: "Profile → Tools → Namecheap API Access")]

    /// Was der Adapter tatsächlich kann; wächst mit den Ressourcen-Erweiterungen.
    public static let capabilityMatrix = CapabilityMatrix(provider: providerID, capabilities:
        CapabilityMatrix.only(.domain, .list, .get, .update)
            .union(CapabilityMatrix.only(.dnsZone, .list))
            .union(CapabilityMatrix.only(.dnsRecord, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.mailForward, .list, .create, .update, .delete))
    )

    public let connection: Connection
    let client: NamecheapClient

    public init(connection: Connection, secrets: any SecretProvider) {
        let connectionID = connection.id
        let settings = connection.settings
        let client = NamecheapClient(credentials: {
            func setting(_ key: String) -> String { (settings[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !setting("api_user").isEmpty else {
                throw KastellanError.invalidArgument("Namecheap: API-Benutzer fehlt in der Verbindung \(connectionID)")
            }
            guard !setting("client_ip").isEmpty else {
                throw KastellanError.invalidArgument("Namecheap: Client-IP fehlt in der Verbindung \(connectionID). Die öffentliche IPv4 eintragen, die im Namecheap-Panel freigegeben ist.")
            }
            guard let key = try await secrets.secret(connectionID: connectionID, key: "api_key"),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KastellanError.unauthorized("Kein Namecheap-API-Key im Schlüsselbund für Verbindung \(connectionID)")
            }
            return .init(apiUser: setting("api_user"), apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines),
                         userName: setting("username"), clientIP: setting("client_ip"))
        }, sandbox: Self.isSandbox(settings["sandbox"]))
        self.init(connection: connection, client: client)
    }

    public init(connection: Connection, client: NamecheapClient) {
        self.connection = connection
        self.client = client
    }

    static func isSandbox(_ value: String?) -> Bool {
        ["1", "true", "ja", "yes", "sandbox"].contains((value ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Prüft Key und IP-Freigabe über die erste Seite der Domainliste.
    public func healthCheck() async -> HealthStatus {
        do {
            let response = try await client.call("namecheap.domains.getList", [("PageSize", "10"), ("Page", "1")])
            let total = response.firstDescendant("Paging")?.child("TotalItems").flatMap { Int($0.text) }
                ?? response.descendants("Domain").count
            let sandbox = Self.isSandbox(connection.settings["sandbox"]) ? " (Sandbox)" : ""
            return HealthStatus(connectionID: connection.id, ok: true, message: "ok, \(total) Domains\(sandbox)")
        } catch KastellanError.unauthorized(let detail) {
            return HealthStatus(connectionID: connection.id, ok: false, message: detail)
        } catch {
            return HealthStatus(connectionID: connection.id, ok: false, message: error.localizedDescription)
        }
    }

    func ref(_ providerRef: String) -> ResourceRef {
        ResourceRef(connectionID: connection.id, providerRef: providerRef)
    }

    static func normalized(_ fqdn: String) -> String {
        fqdn.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    /// Namecheap liefert Datumsangaben als `MM/DD/YYYY`.
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MM/dd/yyyy"
        return f.date(from: text)
    }

    static func isoDay(_ text: String?) -> JSONValue? {
        guard let d = date(text) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return .string(f.string(from: d))
    }
}

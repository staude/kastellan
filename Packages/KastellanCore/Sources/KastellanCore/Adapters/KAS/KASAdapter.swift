import Foundation

// Adapter für All-Inkl KAS. Die Ressourcen-Protokolle sind auf mehrere Dateien verteilt
// (`KASAdapter+Domains.swift` usw.), hier stehen Grundgerüst, Capability-Matrix und Helfer.
// Jeder KAS-Aufruf läuft über `call`, das SOAP-Faults auf `KastellanError.provider` abbildet.

public struct KASAdapter: ProviderAdapter {
    public static let providerID = "allinkl"
    public static let displayName = "All-Inkl (KAS)"
    public static let settingKeys = [SettingKey("kas_login", label: "KAS-Login", placeholder: "w00abcde")]
    public static let secretKeys = [SettingKey("password", label: "KAS-Passwort")]

    /// Was der Adapter tatsächlich kann. Nur hier deklarierte Fähigkeiten lässt der Core zu.
    public static let capabilityMatrix = CapabilityMatrix(provider: providerID, capabilities:
        CapabilityMatrix.full(.domain, except: [.setPassword])
            .union(CapabilityMatrix.only(.subdomain, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.dnsZone, .list))
            .union(CapabilityMatrix.only(.dnsRecord, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.dkim, .get, .create, .delete))
            .union(CapabilityMatrix.full(.mailbox))
            .union(CapabilityMatrix.only(.mailForward, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.mailAutoresponder, .get, .update, .delete))
            .union(CapabilityMatrix.only(.mailingList, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.ftpUser, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.database, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.cronJob, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.certificate, .list, .update))
            .union(CapabilityMatrix.only(.directoryProtection, .list, .create, .delete))
            .union(CapabilityMatrix.only(.subaccount, .list, .create, .delete))
    )

    public let connection: Connection
    let client: KASClient
    let login: String

    public init(connection: Connection, secrets: any SecretProvider) {
        let login = connection.settings["kas_login"] ?? ""
        let connectionID = connection.id
        let client = KASClient(login: login, passwordProvider: {
            guard let password = try await secrets.secret(connectionID: connectionID, key: "password"), !password.isEmpty else {
                throw KastellanError.unauthorized("Kein KAS-Passwort im Schlüsselbund für Verbindung \(connectionID)")
            }
            return password
        })
        self.init(connection: connection, client: client)
    }

    /// Für Tests: Adapter mit vorbereitetem Client (Stub-Transport).
    public init(connection: Connection, client: KASClient) {
        self.connection = connection
        self.client = client
        self.login = connection.settings["kas_login"] ?? ""
    }

    public func healthCheck() async -> HealthStatus {
        do {
            let response = try await call("get_server_information")
            let info = response.returnInfo.array?.first ?? response.returnInfo
            var parts: [String] = ["KAS-Login \(login) erreichbar"]
            if let software = info.string("server_software") ?? info.string("software") { parts.append(software) }
            if let php = info.string("php_version") { parts.append("PHP \(php)") }
            return HealthStatus(connectionID: connection.id, ok: true, message: parts.joined(separator: ", "))
        } catch {
            return HealthStatus(connectionID: connection.id, ok: false, message: error.localizedDescription)
        }
    }

    // MARK: - Helfer für die Ressourcen-Erweiterungen

    func ref(_ providerRef: String) -> ResourceRef {
        ResourceRef(connectionID: connection.id, providerRef: providerRef)
    }

    /// Führt eine KAS-Aktion aus. SOAP-Faults werden zu `KastellanError.provider`,
    /// unbekannte Aktionen zu `KastellanError.unsupported`.
    @discardableResult
    func call(_ action: String, _ params: [String: String] = [:]) async throws -> KASAPIResponse {
        guard !login.isEmpty else {
            throw KastellanError.invalidArgument("Verbindung \(connection.id) hat kein kas_login")
        }
        do {
            return try await client.call(action, params: params)
        } catch let fault as KASFault {
            if fault.isUnknownAction {
                throw KastellanError.unsupported("KAS kennt die Funktion \(action) nicht (\(fault.message))")
            }
            throw fault.kastellanError
        }
    }

    /// Liste der `ReturnInfo`-Maps einer lesenden Aktion.
    func items(_ action: String, _ params: [String: String] = [:]) async throws -> [KASValue] {
        try await call(action, params).items
    }

    /// Alle nicht abgebildeten Felder als `extra`. Passwörter werden nie übernommen.
    static func extra(from item: KASValue, excluding mapped: Set<String>) -> Extra {
        guard let map = item.map else { return [:] }
        var extra: Extra = [:]
        for (key, value) in map where !mapped.contains(key) && !Self.isSecretKey(key) {
            extra[key] = value.jsonValue
        }
        return extra
    }

    static func isSecretKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k.contains("password") || k.contains("passwort") || k == "ssl_certificate_sni_key"
    }

    /// Nur String-Werte aus `extra` als zusätzliche KAS-Parameter (alles andere ignoriert KAS ohnehin).
    static func params(from extra: Extra, allowed: Set<String>? = nil) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in extra {
            if let allowed, !allowed.contains(key) { continue }
            if let s = value.stringValue { out[key] = s }
        }
        return out
    }

    static func yn(_ flag: Bool) -> String { flag ? "Y" : "N" }

    /// Kommagetrennte Liste aus KAS, leer bei `nil`.
    static func list(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Lokalteil und Domain einer Adresse.
    static func split(address: String) throws -> (local: String, domain: String) {
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw KastellanError.invalidArgument("Keine gültige Adresse: \(address)")
        }
        return (parts[0], parts[1].lowercased())
    }

    /// `2027-03-05` als Datum (UTC).
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return dayFormatter.date(from: text)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

public extension KASAdapter {
    /// Bei All-Inkl laufen Mail, FTP und Datenbank auf dem Kontoserver `<login>.kasserver.com`.
    func credentialService(for resource: ResourceType) -> CredentialService? {
        guard let login = connection.settings["kas_login"], !login.isEmpty else { return nil }
        let host = "\(login).kasserver.com"
        switch resource {
        case .mailbox: return CredentialService(host: host, scheme: "imaps", port: 993)
        case .ftpUser: return CredentialService(host: host, scheme: "ftp", port: 21)
        case .database: return CredentialService(host: host, scheme: "mysql", port: 3306)
        case .directoryProtection, .subaccount: return CredentialService(host: host, scheme: "https")
        default: return nil
        }
    }
}

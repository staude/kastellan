import Foundation

// Adapter für Mittwald mStudio (API v2). Ein persönlicher API-Token je Verbindung (Rollen api_read
// oder api_write, optional mit Ablaufdatum). Fast alle Ressourcen hängen an einem Projekt; ohne
// `project_id` in den Einstellungen arbeitet der Adapter über alle Projekte, die der Token sieht
// (optional auf eine Organisation `customer_id` begrenzt). Die Ressourcen-Protokolle folgen in
// eigenen Dateien (`MittwaldAdapter+DNS.swift` usw.).

public struct MittwaldAdapter: ProviderAdapter {
    public static let providerID = "mittwald"
    public static let displayName = "Mittwald"
    public static let settingKeys = [
        SettingKey("project_id", label: "Projekt-ID", placeholder: "optional, UUID des Standardprojekts"),
        SettingKey("customer_id", label: "Organisations-ID", placeholder: "optional, begrenzt auf eine Organisation"),
        SettingKey("mail_host", label: "Mailserver", placeholder: "leer = mail.agenturserver.de"),
    ]
    public static let secretKeys = [SettingKey("api_token", label: "API-Token", placeholder: "aus dem mStudio-Profil, Rolle api_write")]

    /// Was der Adapter tatsächlich kann; wächst mit den schreibenden Erweiterungen.
    public static let capabilityMatrix = CapabilityMatrix(provider: providerID, capabilities:
        CapabilityMatrix.only(.server, .list, .get, .update)
            .union(CapabilityMatrix.only(.domain, .list, .get))
            .union(CapabilityMatrix.only(.subdomain, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.dnsZone, .list))
            .union(CapabilityMatrix.only(.dnsRecord, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.mailbox, .list, .get, .create, .update, .setPassword, .delete))
            .union(CapabilityMatrix.only(.mailForward, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.mailAutoresponder, .get, .update, .delete))
            .union(CapabilityMatrix.only(.database, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.sshUser, .list, .create, .delete))
            .union(CapabilityMatrix.only(.ftpUser, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.cronJob, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.certificate, .list, .update))
            .union(CapabilityMatrix.only(.subaccount, .list, .create, .delete))
    )

    /// Ab so vielen Tagen Restlaufzeit warnt der Health-Check nicht mehr.
    static let tokenWarningDays = 30

    public let connection: Connection
    let client: MittwaldClient

    public init(connection: Connection, secrets: any SecretProvider) {
        let connectionID = connection.id
        let client = MittwaldClient(tokenProvider: {
            guard let token = try await secrets.secret(connectionID: connectionID, key: "api_token"),
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KastellanError.unauthorized("Kein Mittwald-API-Token im Schlüsselbund für Verbindung \(connectionID)")
            }
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        self.init(connection: connection, client: client)
    }

    public init(connection: Connection, client: MittwaldClient) {
        self.connection = connection
        self.client = client
    }

    var projectSetting: String? { connection.settings["project_id"].flatMap { $0.isEmpty ? nil : $0 } }
    var customerSetting: String? { connection.settings["customer_id"].flatMap { $0.isEmpty ? nil : $0 } }

    /// Prüft Token (Session-Status), Ablaufdatum des Tokens und zählt die sichtbaren Projekte.
    public func healthCheck() async -> HealthStatus {
        do {
            let session = try await client.get("/users/self/sessions/current/status")
            let projects = try await listProjects()
            var parts = ["ok, \(projects.count) Projekte"]
            if let projectSetting { parts.append("Standardprojekt \(projectSetting)") }
            if let tokenID = session.string("tokenId"),
               let token = try? await client.list("/users/self/api-tokens").first(where: { $0.string("apiTokenId") == tokenID }) {
                let roles = token.strings("roles")
                if !roles.isEmpty { parts.append("Rollen \(roles.joined(separator: ", "))") }
                if let expires = MittwaldDates.date(token.string("expiresAt")) {
                    let days = Int(expires.timeIntervalSinceNow / 86400)
                    if days < 0 { return HealthStatus(connectionID: connection.id, ok: false, message: "API-Token ist am \(MittwaldDates.day(expires)) abgelaufen") }
                    parts.append(days < Self.tokenWarningDays ? "Token läuft in \(days) Tagen ab" : "Token gültig bis \(MittwaldDates.day(expires))")
                } else {
                    parts.append("Token ohne Ablaufdatum")
                }
            }
            return HealthStatus(connectionID: connection.id, ok: true, message: parts.joined(separator: ", "))
        } catch KastellanError.unauthorized(let detail) {
            return HealthStatus(connectionID: connection.id, ok: false, message: "API-Token abgelehnt (\(detail))")
        } catch {
            return HealthStatus(connectionID: connection.id, ok: false, message: error.localizedDescription)
        }
    }

    // MARK: - Projekte

    /// Alle Projekte, die der Token sieht (optional auf die Organisation begrenzt).
    func listProjects() async throws -> [JSONValue] {
        var query: [(String, String)] = []
        if let customerSetting { query.append(("customerId", customerSetting)) }
        return try await client.list("/projects", query: query)
    }

    /// Projekt-IDs für Listen: das Standardprojekt oder alle sichtbaren.
    func projectIDs(_ extra: Extra = [:]) async throws -> [String] {
        if let id = extra["project_id"]?.stringValue, !id.isEmpty { return [id] }
        if let projectSetting { return [projectSetting] }
        return try await listProjects().compactMap { $0.string("id") }
    }

    /// Genau ein Projekt für schreibende Aufrufe: aus `extra.project_id`, den Einstellungen oder
    /// dem einzigen sichtbaren Projekt; bei mehreren ein Fehler mit Liste.
    func projectID(_ extra: Extra = [:]) async throws -> String {
        if let id = extra["project_id"]?.stringValue, !id.isEmpty { return id }
        if let projectSetting { return projectSetting }
        let projects = try await listProjects()
        if projects.count == 1, let id = projects[0].string("id") { return id }
        let list = projects.map { "\($0.string("description") ?? "?") (\($0.string("shortId") ?? $0.string("id") ?? "?"))" }.joined(separator: ", ")
        throw KastellanError.invalidArgument(projects.isEmpty
            ? "Mittwald: kein Projekt sichtbar"
            : "Mittwald: mehrere Projekte, extra.project_id oder Verbindungs-Einstellung Projekt-ID angeben: \(list)")
    }

    func ref(_ providerRef: String) -> ResourceRef {
        ResourceRef(connectionID: connection.id, providerRef: providerRef)
    }

    static func extra(from item: JSONValue, keys: [String]) -> Extra {
        var extra: Extra = [:]
        for key in keys {
            if let v = item[key], v != .null { extra[key] = v }
        }
        return extra
    }
}

enum MittwaldDates {
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

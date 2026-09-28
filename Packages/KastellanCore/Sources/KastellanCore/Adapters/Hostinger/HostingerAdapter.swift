import Foundation

// Adapter für Hostinger (hPanel-API). Ein API-Token je Verbindung (hPanel → Profil → API), ohne
// Scopes: der Token hat alle Rechte des Nutzers. Die Ressourcen-Protokolle folgen in eigenen
// Dateien (`HostingerAdapter+DNS.swift` usw.); hier stehen Grundgerüst, Capability-Matrix und
// Health-Check.

public struct HostingerAdapter: ProviderAdapter {
    public static let providerID = "hostinger"
    public static let displayName = "Hostinger"
    public static let settingKeys = [
        SettingKey("website", label: "Webhosting-Domain", placeholder: "optional, Standard-Website für Datenbanken und Cronjobs"),
        SettingKey("mail_host", label: "Mailserver", placeholder: "leer = imap.hostinger.com"),
    ]
    public static let secretKeys = [SettingKey("api_token", label: "API-Token", placeholder: "aus dem hPanel unter Profil → API")]

    /// Was der Adapter tatsächlich kann; wächst mit den Ressourcen-Erweiterungen.
    public static let capabilityMatrix = CapabilityMatrix(provider: providerID, capabilities:
        CapabilityMatrix.only(.domain, .list, .get, .update)
            .union(CapabilityMatrix.only(.dnsZone, .list))
            .union(CapabilityMatrix.only(.dnsRecord, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.server, .list, .get, .update))
            .union(CapabilityMatrix.only(.firewall, .list, .get))
            .union(CapabilityMatrix.only(.sshUser, .list, .create, .delete))
            .union(CapabilityMatrix.only(.mailbox, .list, .get, .create, .update, .setPassword, .delete))
            .union(CapabilityMatrix.only(.mailForward, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.mailAutoresponder, .get, .update, .delete))
            .union(CapabilityMatrix.only(.subdomain, .list, .create, .delete))
            .union(CapabilityMatrix.only(.database, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.cronJob, .list, .create, .update, .delete))
    )

    public let connection: Connection
    let client: HostingerClient

    public init(connection: Connection, secrets: any SecretProvider) {
        let connectionID = connection.id
        let client = HostingerClient(tokenProvider: {
            guard let token = try await secrets.secret(connectionID: connectionID, key: "api_token"),
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KastellanError.unauthorized("Kein Hostinger-API-Token im Schlüsselbund für Verbindung \(connectionID)")
            }
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        self.init(connection: connection, client: client)
    }

    public init(connection: Connection, client: HostingerClient) {
        self.connection = connection
        self.client = client
    }

    /// Prüft den Token über das Domain-Portfolio; ohne Domains über die Abonnements.
    public func healthCheck() async -> HealthStatus {
        do {
            let domains = try await client.list("/api/domains/v1/portfolio")
            var parts = ["ok, \(domains.count) Domains"]
            if let subscriptions = try? await client.list("/api/billing/v1/subscriptions") {
                let active = subscriptions.filter { ["active", "in_trial"].contains($0.string("status") ?? "") }.count
                parts.append("\(active) aktive Abonnements")
            }
            if let remaining = await client.rateLimitRemaining { parts.append("Rate-Limit \(remaining) übrig") }
            return HealthStatus(connectionID: connection.id, ok: true, message: parts.joined(separator: ", "))
        } catch KastellanError.unauthorized(let detail) {
            return HealthStatus(connectionID: connection.id, ok: false, message: "API-Token abgelehnt (\(detail))")
        } catch {
            return HealthStatus(connectionID: connection.id, ok: false, message: error.localizedDescription)
        }
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

enum HostingerDates {
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: text) { return d }
        // `2026-01-01 00:00:00` ohne Zeitzone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: text)
    }
}

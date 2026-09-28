import Foundation

// Adapter für Cloudflare (REST v4 mit API-Token). Die Ressourcen-Protokolle liegen in
// `CloudflareAdapter+DNS.swift` usw., hier stehen Grundgerüst, Capability-Matrix und Helfer.
// Jeder Aufruf läuft über den `CloudflareClient`, der Envelope-Fehler auf `KastellanError.provider`
// abbildet, blättert und drosselt.

public struct CloudflareAdapter: ProviderAdapter {
    public static let providerID = "cloudflare"
    public static let displayName = "Cloudflare"
    public static let settingKeys = [SettingKey("account_id", label: "Account-ID", placeholder: "optional, für Email-Routing-Ziele")]
    public static let secretKeys = [SettingKey("api_token", label: "API-Token", placeholder: "Konto- oder Zonen-Token")]

    /// Was der Adapter tatsächlich kann. Nur hier deklarierte Fähigkeiten lässt der Core zu.
    public static let capabilityMatrix = CapabilityMatrix(provider: providerID, capabilities:
        CapabilityMatrix.only(.dnsZone, .list)
            .union(CapabilityMatrix.only(.dnsRecord, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.mailForward, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.certificate, .list, .update))
    )

    public let connection: Connection
    let client: CloudflareClient

    public init(connection: Connection, secrets: any SecretProvider) {
        let connectionID = connection.id
        let client = CloudflareClient(tokenProvider: {
            guard let token = try await secrets.secret(connectionID: connectionID, key: "api_token"), !token.isEmpty else {
                throw KastellanError.unauthorized("Kein Cloudflare-API-Token im Schlüsselbund für Verbindung \(connectionID)")
            }
            return token
        })
        self.init(connection: connection, client: client)
    }

    /// Für Tests: Adapter mit vorbereitetem Client (Stub-Transport).
    public init(connection: Connection, client: CloudflareClient) {
        self.connection = connection
        self.client = client
    }

    /// Account-ID aus den Verbindungseinstellungen, leer wenn nicht gesetzt.
    var accountID: String? {
        let id = connection.settings["account_id"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty ? nil : id
    }

    /// `GET /user/tokens/verify` für Nutzer-Tokens; kontogebundene Tokens kennen nur
    /// `GET /accounts/{id}/tokens/verify`. Beides wird probiert.
    public func healthCheck() async -> HealthStatus {
        var attempts: [String] = ["/user/tokens/verify"]
        if let account = connection.settings["account_id"]?.trimmingCharacters(in: .whitespaces), !account.isEmpty {
            attempts.append("/accounts/\(account)/tokens/verify")
        }
        var lastError = "unbekannt"
        for path in attempts {
            do {
                let info: CloudflareTokenVerification = try await client.get(path)
                let active = info.status.lowercased() == "active"
                let kind = path.hasPrefix("/accounts") ? "Konto-Token" : "Nutzer-Token"
                var message = active ? "Cloudflare \(kind) aktiv" : "Cloudflare \(kind) \(info.status)"
                if let expires = info.expiresOn, !expires.isEmpty { message += ", gültig bis \(expires)" }
                return HealthStatus(connectionID: connection.id, ok: active, message: message)
            } catch {
                lastError = error.localizedDescription
            }
        }
        var hint = ""
        if lastError.contains("Invalid API Token") {
            hint = " Prüfen: ist es ein API-Token (nicht der Global API Key), ohne Leerzeichen kopiert? Ein Konto-Token braucht die Account-ID im Feld darüber."
        }
        return HealthStatus(connectionID: connection.id, ok: false, message: lastError + hint)
    }

    // MARK: - Helfer für die Ressourcen-Erweiterungen

    func ref(_ providerRef: String) -> ResourceRef {
        ResourceRef(connectionID: connection.id, providerRef: providerRef)
    }

    /// Zonen-ID über den Cache des Clients.
    func zoneID(_ zone: String) async throws -> String {
        try await client.zoneID(for: zone)
    }

    /// Kanonischer Zonenname ohne Punkt am Ende, kleingeschrieben.
    static func zoneName(_ zone: String) -> String {
        CloudflareClient.zoneName(zone)
    }

    /// `2026-12-31T23:59:59Z` oder mit Nachkommastellen (`.000000Z`) als Datum.
    static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        // Cloudflare liefert sechs Nachkommastellen, der Parser versteht drei.
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = text[text.index(after: dot)..<end]
            text.replaceSubrange(dot..<end, with: digits.isEmpty ? "" : "." + digits.prefix(3))
        }
        // `ISO8601FormatStyle` ist Sendable, `ISO8601DateFormatter` nicht.
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}

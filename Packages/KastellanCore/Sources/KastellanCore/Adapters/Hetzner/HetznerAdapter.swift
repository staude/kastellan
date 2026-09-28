import Foundation

// Adapter für die Hetzner Cloud API (ein Token je Projekt). Die Ressourcen-Protokolle sind auf
// mehrere Dateien verteilt (`HetznerAdapter+DNS.swift` usw.), hier stehen Grundgerüst,
// Capability-Matrix und Helfer. Alle Aufrufe laufen über `HetznerClient`, der Fehlerhülle,
// Rate-Limit und Action-Polling übernimmt.

public struct HetznerAdapter: ProviderAdapter {
    public static let providerID = "hetzner"
    public static let displayName = "Hetzner Cloud"
    public static let settingKeys = [SettingKey("project", label: "Projektname", placeholder: "nur zur Anzeige")]
    public static let secretKeys = [SettingKey("api_token", label: "API-Token", placeholder: "Projekt-Token aus der Cloud Console")]

    /// Was der Adapter tatsächlich kann. Nur hier deklarierte Fähigkeiten lässt der Core zu.
    public static let capabilityMatrix = CapabilityMatrix(provider: providerID, capabilities:
        CapabilityMatrix.only(.dnsZone, .list)
            .union(CapabilityMatrix.only(.dnsRecord, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.server, .list, .get, .create, .update, .delete))
            .union(CapabilityMatrix.only(.sshUser, .list, .create, .delete))
            .union(CapabilityMatrix.only(.firewall, .list, .get))
    )

    public let connection: Connection
    let client: HetznerClient

    public init(connection: Connection, secrets: any SecretProvider) {
        let connectionID = connection.id
        let client = HetznerClient(tokenProvider: {
            guard let token = try await secrets.secret(connectionID: connectionID, key: "api_token"), !token.isEmpty else {
                throw KastellanError.unauthorized("Kein Hetzner-API-Token im Schlüsselbund für Verbindung \(connectionID)")
            }
            return token
        })
        self.init(connection: connection, client: client)
    }

    /// Für Tests: Adapter mit vorbereitetem Client (Stub-Transport).
    public init(connection: Connection, client: HetznerClient) {
        self.connection = connection
        self.client = client
    }

    /// Prüft Token und Erreichbarkeit über die billigste Liste (`/ssh_keys?per_page=1`).
    public func healthCheck() async -> HealthStatus {
        do {
            let response = try await client.get("/ssh_keys", query: [("per_page", "1")])
            let count = response["meta"]?["pagination"]?.int("total_entries") ?? response.array("ssh_keys").count
            var message = "ok, \(count) SSH-Keys"
            if let project = connection.settings["project"], !project.isEmpty { message = "Projekt \(project): " + message }
            if let remaining = await client.rateLimitRemaining { message += ", Rate-Limit \(remaining) übrig" }
            return HealthStatus(connectionID: connection.id, ok: true, message: message)
        } catch KastellanError.unauthorized(let detail) {
            return HealthStatus(connectionID: connection.id, ok: false, message: "API-Token abgelehnt (\(detail))")
        } catch {
            return HealthStatus(connectionID: connection.id, ok: false, message: error.localizedDescription)
        }
    }

    // MARK: - Helfer für die Ressourcen-Erweiterungen

    func ref(_ providerRef: String) -> ResourceRef {
        ResourceRef(connectionID: connection.id, providerRef: providerRef)
    }

    /// Ausgewählte Provider-Felder als `extra`; fehlende Felder werden weggelassen.
    static func extra(from item: JSONValue, keys: [String]) -> Extra {
        var extra: Extra = [:]
        for key in keys {
            if let v = item[key], v != .null { extra[key] = v }
        }
        return extra
    }
}

public extension HetznerAdapter {
    func credentialService(for resource: ResourceType) -> CredentialService? {
        resource == .server ? CredentialService(host: "hetzner.cloud", scheme: "ssh", port: 22) : nil
    }
}

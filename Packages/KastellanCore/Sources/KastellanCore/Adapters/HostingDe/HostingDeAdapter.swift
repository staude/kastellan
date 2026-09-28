import Foundation

// Adapter für hosting.de (auch http.net, gleiche Plattform). Ein API-Key je Verbindung, erzeugt
// im Kundenpanel mit eigenem Rechtesatz. Die Ressourcen-Protokolle folgen in eigenen Dateien
// (`HostingDeAdapter+DNS.swift` usw.); hier stehen Grundgerüst, Capability-Matrix und Health-Check.

public struct HostingDeAdapter: ProviderAdapter {
    public static let providerID = "hostingde"
    public static let displayName = "hosting.de"
    public static let settingKeys = [
        SettingKey("account_id", label: "Unterkonto-ID", placeholder: "optional, Aufrufe im Namen eines Unterkontos"),
        SettingKey("base_url", label: "API-Basis", placeholder: "leer = hosting.de, http.net: https://partner.http.net/api"),
        SettingKey("mailbox_product", label: "Produktcode Postfach", placeholder: "leer = \(HostingDeAdapter.defaultMailboxProduct)"),
    ]
    public static let secretKeys = [SettingKey("api_key", label: "API-Key", placeholder: "aus dem Kundenpanel, landet im Schlüsselbund")]

    /// Was der Adapter tatsächlich kann. Wächst mit den Ressourcen-Erweiterungen.
    public static let capabilityMatrix = CapabilityMatrix(provider: providerID, capabilities:
        CapabilityMatrix.only(.dnsZone, .list)
            .union(CapabilityMatrix.only(.dnsRecord, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.domain, .list, .get))
            .union(CapabilityMatrix.only(.subdomain, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.mailbox, .list, .get, .create, .update, .setPassword, .delete))
            .union(CapabilityMatrix.only(.mailForward, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.mailAutoresponder, .get, .update, .delete))
            .union(CapabilityMatrix.only(.mailingList, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.ftpUser, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.sshUser, .list, .create, .delete))
            .union(CapabilityMatrix.only(.database, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.cronJob, .list, .create, .update, .delete))
            .union(CapabilityMatrix.only(.directoryProtection, .list, .create, .delete))
            .union(CapabilityMatrix.only(.certificate, .list, .update))
            .union(CapabilityMatrix.only(.server, .list, .get, .create, .update, .delete))
            .union(CapabilityMatrix.only(.subaccount, .list))
    )

    public let connection: Connection
    let client: HostingDeClient

    public init(connection: Connection, secrets: any SecretProvider) {
        let connectionID = connection.id
        let base = connection.settings["base_url"].flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? HostingDeClient.defaultBaseURL
        let client = HostingDeClient(tokenProvider: {
            guard let key = try await secrets.secret(connectionID: connectionID, key: "api_key"),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KastellanError.unauthorized("Kein hosting.de-API-Key im Schlüsselbund für Verbindung \(connectionID)")
            }
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }, ownerAccountID: connection.settings["account_id"], baseURL: base)
        self.init(connection: connection, client: client)
    }

    /// Für Tests: Adapter mit vorbereitetem Client (Stub-Transport).
    public init(connection: Connection, client: HostingDeClient) {
        self.connection = connection
        self.client = client
    }

    /// Prüft Key und Erreichbarkeit über die billigste Liste (`zoneConfigsFind` mit einer Zeile).
    public func healthCheck() async -> HealthStatus {
        do {
            let zones = try await client.findPage("dns", "zoneConfigsFind", limit: 1)
            var message = "ok, \(zones.total) DNS-Zonen"
            if let account = connection.settings["account_id"], !account.isEmpty { message += ", Unterkonto \(account)" }
            return HealthStatus(connectionID: connection.id, ok: true, message: message)
        } catch KastellanError.unauthorized(let detail) {
            return HealthStatus(connectionID: connection.id, ok: false, message: "API-Key abgelehnt (\(detail))")
        } catch {
            return HealthStatus(connectionID: connection.id, ok: false, message: error.localizedDescription)
        }
    }

    // MARK: - Helfer für die Ressourcen-Erweiterungen

    func ref(_ providerRef: String) -> ResourceRef {
        ResourceRef(connectionID: connection.id, providerRef: providerRef)
    }

    /// Dienst-Adressen für Login-Einträge: Mail über mail.hosting.de (IMAP 993), FTP und MySQL
    /// über die generierten Hostnamen der Webspaces und Datenbanken (erst nach dem Lesen bekannt).
    public func credentialService(for resource: ResourceType) -> CredentialService? {
        switch resource {
        case .mailbox: return CredentialService(host: connection.settings["mail_host"].flatMap { $0.isEmpty ? nil : $0 } ?? "mail.hosting.de", scheme: "imaps", port: 993)
        default: return nil
        }
    }

    static func extra(from item: JSONValue, keys: [String]) -> Extra {
        var extra: Extra = [:]
        for key in keys {
            if let v = item[key], v != .null { extra[key] = v }
        }
        return extra
    }
}

import Foundation

// Adapter-Verträge (Konzept, Abschnitt 8). Ein Adapter implementiert nur die Protokolle,
// die der Provider hergibt, und deklariert das statisch in seiner CapabilityMatrix.
// Vorbild libdns: kleine Interfaces pro Ressourcentyp.

/// Liefert Secrets für einen Adapter. Implementierungen: Schlüsselbund (App, MCP) und In-Memory (Tests).
public protocol SecretProvider: Sendable {
    func secret(connectionID: String, key: String) async throws -> String?
}

/// Schreibender Zugriff, nur für App und generierte Passwörter.
public protocol SecretStore: SecretProvider {
    func set(connectionID: String, key: String, value: String) async throws
    func delete(connectionID: String, key: String) async throws
}

/// Basis jedes Adapters.
public protocol ProviderAdapter: Sendable {
    /// Kurzkennung, etwa `allinkl`, `mittwald`, `cloudflare`.
    static var providerID: String { get }
    static var displayName: String { get }
    static var capabilityMatrix: CapabilityMatrix { get }
    /// Nicht geheime Einstellungen, die eine Verbindung braucht (Schlüssel in `Connection.settings`).
    static var settingKeys: [SettingKey] { get }
    /// Geheime Einstellungen, die im Schlüsselbund liegen.
    static var secretKeys: [SettingKey] { get }

    init(connection: Connection, secrets: any SecretProvider)

    var connection: Connection { get }
    func healthCheck() async -> HealthStatus
}

public struct SettingKey: Hashable, Sendable {
    public let key: String
    public let label: String
    public let placeholder: String

    public init(_ key: String, label: String, placeholder: String = "") {
        self.key = key; self.label = label; self.placeholder = placeholder
    }
}

/// Dienst-Adresse für Login-Einträge, etwa der Mailserver zu einem Postfach.
public struct CredentialService: Sendable, Equatable {
    public var host: String
    public var scheme: String
    public var port: Int?
    public init(host: String, scheme: String, port: Int? = nil) { self.host = host; self.scheme = scheme; self.port = port }
}

public extension ProviderAdapter {
    /// Standard: keine Dienst-Adresse bekannt. Adapter überschreiben das, wo sie den Host kennen.
    func credentialService(for resource: ResourceType) -> CredentialService? { nil }
}

public extension ProviderAdapter {
    static var displayName: String { providerID }
    var capabilityMatrix: CapabilityMatrix { Self.capabilityMatrix }
    func supports(_ capability: Capability) -> Bool { Self.capabilityMatrix.supports(capability) }
}

// MARK: - Ressourcen-Protokolle

public protocol DomainAdapter: ProviderAdapter {
    func listDomains() async throws -> [Domain]
    func getDomain(fqdn: String) async throws -> Domain?
    func createDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain
    func updateDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain
    func deleteDomain(fqdn: String) async throws
}

public protocol SubdomainAdapter: ProviderAdapter {
    func listSubdomains(parent: String?) async throws -> [Subdomain]
    func createSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain
    func updateSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain
    func deleteSubdomain(fqdn: String) async throws
}

public protocol DNSAdapter: ProviderAdapter {
    func listZones() async throws -> [DNSZone]
    func listRecords(zone: String) async throws -> [DNSRecord]
    func createRecord(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) async throws -> DNSRecord
    func updateRecord(zone: String, providerRef: String, content: String?, ttl: Int?, priority: Int?) async throws -> DNSRecord
    func deleteRecord(zone: String, providerRef: String) async throws
    /// Diff-Semantik. Default: Änderungen nacheinander als Einzelaufrufe.
    func applyChanges(zone: String, changes: [DNSChange]) async throws -> [DNSRecord]
}

public extension DNSAdapter {
    func applyChanges(zone: String, changes: [DNSChange]) async throws -> [DNSRecord] {
        var touched: [DNSRecord] = []
        for change in changes {
            switch change {
            case let .create(name, type, content, ttl, priority):
                touched.append(try await createRecord(zone: zone, name: name, type: type, content: content, ttl: ttl, priority: priority))
            case let .update(providerRef, content, ttl, priority):
                touched.append(try await updateRecord(zone: zone, providerRef: providerRef, content: content, ttl: ttl, priority: priority))
            case let .delete(providerRef):
                try await deleteRecord(zone: zone, providerRef: providerRef)
            }
        }
        return touched
    }
}

public protocol MailboxAdapter: ProviderAdapter {
    func listMailboxes(domain: String?) async throws -> [Mailbox]
    func getMailbox(address: String) async throws -> Mailbox?
    func createMailbox(_ spec: MailboxSpec) async throws -> Mailbox
    func updateMailbox(_ spec: MailboxSpec) async throws -> Mailbox
    func setMailboxPassword(address: String, password: String) async throws
    func deleteMailbox(address: String) async throws
}

public protocol MailForwardAdapter: ProviderAdapter {
    func listForwards(domain: String?) async throws -> [MailForward]
    func createForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward
    func updateForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward
    func deleteForward(address: String) async throws
}

public protocol MailAutoresponderAdapter: ProviderAdapter {
    func getAutoresponder(address: String) async throws -> MailAutoresponder?
    func setAutoresponder(_ responder: MailAutoresponder) async throws -> MailAutoresponder
    func clearAutoresponder(address: String) async throws
}

public protocol MailingListAdapter: ProviderAdapter {
    func listMailingLists(domain: String?) async throws -> [MailingList]
    func createMailingList(address: String, members: [String], extra: Extra) async throws -> MailingList
    func updateMailingList(address: String, members: [String], extra: Extra) async throws -> MailingList
    func deleteMailingList(address: String) async throws
}

public protocol DKIMAdapter: ProviderAdapter {
    func getDKIM(domain: String) async throws -> DKIMKey?
    func createDKIM(domain: String) async throws -> DKIMKey
    func deleteDKIM(domain: String) async throws
}

public protocol FTPUserAdapter: ProviderAdapter {
    func listFTPUsers() async throws -> [FTPUser]
    func createFTPUser(username: String?, password: String, homePath: String, comment: String?) async throws -> FTPUser
    func updateFTPUser(username: String, password: String?, homePath: String?, comment: String?) async throws -> FTPUser
    func deleteFTPUser(username: String) async throws
}

public protocol SSHUserAdapter: ProviderAdapter {
    func listSSHUsers() async throws -> [SSHUser]
    func createSSHUser(username: String?, publicKeys: [String]) async throws -> SSHUser
    func deleteSSHUser(username: String) async throws
}

public protocol ServerAdapter: ProviderAdapter {
    func listServers() async throws -> [Server]
    func getServer(providerRef: String) async throws -> Server?
    func createServer(_ spec: ServerSpec) async throws -> Server
    /// Umbenennen, Labels setzen oder eine Power-Aktion ausführen (jeweils optional).
    func updateServer(providerRef: String, name: String?, labels: [String: String]?, power: ServerPowerAction?) async throws -> Server
    func deleteServer(providerRef: String) async throws
}

public protocol FirewallAdapter: ProviderAdapter {
    func listFirewalls() async throws -> [Firewall]
    func getFirewall(providerRef: String) async throws -> Firewall?
}

public protocol DatabaseAdapter: ProviderAdapter {
    func listDatabases() async throws -> [Database]
    func createDatabase(password: String, comment: String?, allowedHosts: [String]) async throws -> Database
    func updateDatabase(name: String, password: String?, comment: String?, allowedHosts: [String]?) async throws -> Database
    func deleteDatabase(name: String) async throws
}

public protocol CronJobAdapter: ProviderAdapter {
    func listCronJobs() async throws -> [CronJob]
    func createCronJob(schedule: String, url: String?, command: String?, comment: String?) async throws -> CronJob
    func updateCronJob(providerRef: String, schedule: String?, url: String?, command: String?, comment: String?, active: Bool?) async throws -> CronJob
    func deleteCronJob(providerRef: String) async throws
}

public protocol CertificateAdapter: ProviderAdapter {
    func listCertificates() async throws -> [Certificate]
    func updateCertificate(hostname: String, forceHTTPS: Bool?, extra: Extra) async throws -> Certificate
}

public protocol DirectoryProtectionAdapter: ProviderAdapter {
    func listDirectoryProtections() async throws -> [DirectoryProtection]
    func createDirectoryProtection(path: String, username: String, password: String, realm: String?) async throws -> DirectoryProtection
    func deleteDirectoryProtection(path: String, username: String?) async throws
}

public protocol SubaccountAdapter: ProviderAdapter {
    func listSubaccounts() async throws -> [Subaccount]
    func createSubaccount(password: String, comment: String?, extra: Extra) async throws -> Subaccount
    func deleteSubaccount(login: String) async throws
}

// MARK: - Registry

/// Kennt alle eingebauten Adapter und erzeugt sie für eine Verbindung.
public struct AdapterRegistry: Sendable {
    public struct Entry: Sendable {
        public let providerID: String
        public let displayName: String
        public let capabilityMatrix: CapabilityMatrix
        public let settingKeys: [SettingKey]
        public let secretKeys: [SettingKey]
        let make: @Sendable (Connection, any SecretProvider) -> any ProviderAdapter

        public init<A: ProviderAdapter>(_ type: A.Type) {
            providerID = A.providerID
            displayName = A.displayName
            capabilityMatrix = A.capabilityMatrix
            settingKeys = A.settingKeys
            secretKeys = A.secretKeys
            make = { A(connection: $0, secrets: $1) }
        }
    }

    public var entries: [String: Entry] = [:]

    public init(_ entries: [Entry] = []) {
        for e in entries { self.entries[e.providerID] = e }
    }

    public mutating func register<A: ProviderAdapter>(_ type: A.Type) {
        entries[A.providerID] = Entry(type)
    }

    public func entry(for providerID: String) -> Entry? { entries[providerID] }

    public func adapter(for connection: Connection, secrets: any SecretProvider) throws -> any ProviderAdapter {
        guard let e = entries[connection.provider] else {
            throw KastellanError.unsupported("Provider \(connection.provider) unbekannt")
        }
        return e.make(connection, secrets)
    }

    public func capabilityMatrix(for providerID: String) -> CapabilityMatrix? {
        entries[providerID]?.capabilityMatrix
    }
}

/// Secrets im Speicher, für Tests und Probeläufe.
public actor InMemorySecretProvider: SecretStore {
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func secret(connectionID: String, key: String) async throws -> String? {
        values["\(connectionID)/\(key)"]
    }

    public func set(connectionID: String, key: String, value: String) {
        values["\(connectionID)/\(key)"] = value
    }

    public func delete(connectionID: String, key: String) {
        values.removeValue(forKey: "\(connectionID)/\(key)")
    }
}

public extension CapabilityMatrix {
    /// Bequeme Deklaration: alle Aktionen eines Ressourcentyps.
    static func full(_ resource: ResourceType, except excluded: Set<Action> = []) -> Set<Capability> {
        Set(Action.allCases.filter { !excluded.contains($0) }.map { Capability(resource, $0) })
    }

    static func only(_ resource: ResourceType, _ actions: Action...) -> Set<Capability> {
        Set(actions.map { Capability(resource, $0) })
    }

    /// Ressourcentypen mit mindestens einer Fähigkeit.
    var resources: Set<ResourceType> { Set(capabilities.map(\.resource)) }
}

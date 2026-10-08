/// Gemeinsamer Kern von Kastellan.app und kastellan-mcp.
/// Kennt weder UI noch MCP-SDK. Siehe Vault, `02 Projekte/Kastellan — Konzept.md`.
public enum KastellanCore {
    public static let version = "0.3.0"
}

/// Kanonische Ressourcentypen (Konzept, Abschnitt 6).
public enum ResourceType: String, Codable, CaseIterable, Sendable {
    case connection
    case domain
    case subdomain
    case dnsZone = "dns_zone"
    case dnsRecord = "dns_record"
    case mailbox
    case mailForward = "mail_forward"
    case mailAutoresponder = "mail_autoresponder"
    case mailingList = "mailing_list"
    case dkim
    case ftpUser = "ftp_user"
    case sshUser = "ssh_user"
    case database
    case databaseUser = "database_user"
    case cronJob = "cron_job"
    case certificate
    case directoryProtection = "directory_protection"
    case subaccount
    case server
    case firewall
}

public extension ResourceType {
    /// Gruppen für Schnellwahl in der Zuordnung.
    enum Group: String, CaseIterable, Sendable {
        case web = "Web", mail = "Mail", dns = "DNS", server = "Server", account = "Konto"
        public var members: [ResourceType] { ResourceType.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .domain, .subdomain, .certificate, .directoryProtection, .ftpUser, .cronJob, .database, .databaseUser: .web
        case .mailbox, .mailForward, .mailAutoresponder, .mailingList, .dkim: .mail
        case .dnsZone, .dnsRecord: .dns
        case .server, .firewall, .sshUser: .server
        case .connection, .subaccount: .account
        }
    }

    var displayName: String {
        switch self {
        case .connection: "Verbindung"
        case .domain: "Domain"
        case .subdomain: "Subdomain"
        case .dnsZone: "DNS-Zone"
        case .dnsRecord: "DNS-Record"
        case .mailbox: "Postfach"
        case .mailForward: "Weiterleitung"
        case .mailAutoresponder: "Autoresponder"
        case .mailingList: "Mailingliste"
        case .dkim: "DKIM"
        case .ftpUser: "FTP-Zugang"
        case .sshUser: "SSH-Zugang oder SSH-Key"
        case .database: "Datenbank"
        case .databaseUser: "Datenbank-Benutzer"
        case .cronJob: "Cronjob"
        case .certificate: "Zertifikat"
        case .directoryProtection: "Verzeichnisschutz"
        case .subaccount: "Subaccount"
        case .server: "Server"
        case .firewall: "Firewall"
        }
    }

    /// Kurze Erklärung, was beim Hoster damit gemeint ist.
    var explanation: String {
        switch self {
        case .connection: "Ein Zugang zu einem Hoster-Account, mit Login und Secret im Schlüsselbund."
        case .domain: "Eine Domain im Hosting-Paket, etwa example.de: Webspace-Pfad, PHP-Version, Weiterleitung. Nicht die DNS-Einträge und nicht die Registrierung."
        case .subdomain: "Ein Unterbereich einer Domain, etwa app.example.de, mit eigenem Webspace-Pfad oder eigener Weiterleitung."
        case .dnsZone: "Der komplette Satz DNS-Einträge einer Domain beim Nameserver-Betreiber, etwa bei Cloudflare oder Hetzner."
        case .dnsRecord: "Ein einzelner DNS-Eintrag in einer Zone: A, AAAA, CNAME, TXT, MX. MX, NS und SOA gelten als geschützt."
        case .mailbox: "Ein E-Mail-Postfach mit Login und Speicher, das Mails empfängt und sendet."
        case .mailForward: "Eine Adresse, die Mails an andere Adressen weiterleitet, ohne eigenes Postfach. Deckt auch Aliase ab."
        case .mailAutoresponder: "Automatische Antwort eines Postfachs, etwa bei Abwesenheit."
        case .mailingList: "Eine Verteilerliste: eine Adresse, viele Empfänger."
        case .dkim: "Signaturschlüssel für ausgehende Mails einer Domain. Der Hoster erzeugt ihn, der Public Key gehört als TXT-Record ins DNS."
        case .ftpUser: "Ein FTP- oder SFTP-Login auf den Webspace, mit Startverzeichnis."
        case .sshUser: "Ein SSH-Login beim Hoster oder ein hinterlegter SSH-Key, etwa bei Hetzner Cloud."
        case .database: "Eine MySQL- oder MariaDB-Datenbank mit Login und Passwort."
        case .databaseUser: "Ein zusätzlicher Benutzer einer Datenbank mit eigenen Rechten."
        case .cronJob: "Ein zeitgesteuerter Aufruf, bei All-Inkl als HTTP-Aufruf einer URL."
        case .certificate: "Das TLS-Zertifikat eines Hostnamens, Let’s Encrypt oder hochgeladen, und ob HTTPS erzwungen wird."
        case .directoryProtection: "Passwortschutz für ein Verzeichnis auf dem Webspace (htaccess)."
        case .subaccount: "Ein eigenständiger Unter-Account beim Hoster mit eigenem Login."
        case .server: "Ein virtueller Server in der Cloud: Status, IPs, Typ, Standort, Ein- und Ausschalten."
        case .firewall: "Regeln, welche Ports und Quellen einen Cloud-Server erreichen dürfen."
        }
    }
}

/// Aktionen im Audit-Vokabular `resource:action`.
public enum Action: String, Codable, CaseIterable, Sendable {
    case list, get, create, update, setPassword = "set_password", delete
}

/// Rechtestufen pro Ressourcentyp (Konzept, Abschnitt 7). Jede Stufe umfasst die darunter.
public enum PermissionLevel: String, Codable, Comparable, CaseIterable, Sendable {
    case none, read, write, manage

    private var rank: Int {
        switch self {
        case .none: 0
        case .read: 1
        case .write: 2
        case .manage: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Kleinste Stufe, die eine Aktion erlaubt.
    public static func required(for action: Action) -> PermissionLevel {
        switch action {
        case .list, .get: .read
        case .create, .update, .setPassword: .write
        case .delete: .manage
        }
    }
}

/// Kurzschreibweise `mailbox:create` für Audit, Tool-Namen und Fehlermeldungen.
public struct Capability: Hashable, Codable, Sendable, CustomStringConvertible {
    public let resource: ResourceType
    public let action: Action

    public init(_ resource: ResourceType, _ action: Action) {
        self.resource = resource
        self.action = action
    }

    public var description: String { "\(resource.rawValue):\(action.rawValue)" }

    /// Liest `mailbox:create`.
    public init?(parsing text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let r = ResourceType(rawValue: parts[0]), let a = Action(rawValue: parts[1]) else { return nil }
        self.init(r, a)
    }
}

/// Statische Deklaration eines Adapters: welche Ressourcen und Aktionen der Provider kann.
public struct CapabilityMatrix: Sendable {
    public let provider: String
    public let capabilities: Set<Capability>

    public init(provider: String, capabilities: Set<Capability>) {
        self.provider = provider
        self.capabilities = capabilities
    }

    public func supports(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }
}

/// Rechte eines Client-Tokens auf einer Verbindung (Konzept, Abschnitt 7).
public struct Policy: Codable, Sendable, Equatable {
    public var levels: [ResourceType: PermissionLevel]
    public var domainPatterns: [String]
    public var excludedTargets: [String]
    public var scopes: PolicyScopes
    /// Zusätzliche Bestätigungspflichten, als `resource:action`.
    public var confirmExtra: [String]
    public var maxWritesPerHour: Int?
    public var agentMayConfirm: Bool
    /// Generierte Passwörter im Tool-Ergebnis zeigen statt nur im Schlüsselbund abzulegen.
    public var revealGeneratedPasswords: Bool

    public init(
        levels: [ResourceType: PermissionLevel] = [:],
        domainPatterns: [String] = [],
        excludedTargets: [String] = [],
        scopes: PolicyScopes = PolicyScopes(),
        confirmExtra: [String] = [],
        maxWritesPerHour: Int? = nil,
        agentMayConfirm: Bool = false,
        revealGeneratedPasswords: Bool = false
    ) {
        self.levels = levels
        self.domainPatterns = domainPatterns
        self.excludedTargets = excludedTargets
        self.scopes = scopes
        self.confirmExtra = confirmExtra
        self.maxWritesPerHour = maxWritesPerHour
        self.agentMayConfirm = agentMayConfirm
        self.revealGeneratedPasswords = revealGeneratedPasswords
    }

    public func level(for resource: ResourceType) -> PermissionLevel {
        levels[resource] ?? .none
    }

    public var extraConfirmations: Set<Capability> {
        Set(confirmExtra.compactMap(Capability.init(parsing:)))
    }

    enum CodingKeys: String, CodingKey {
        case levels = "permissions"
        case domainPatterns = "domains"
        case excludedTargets = "exclude"
        case scopes
        case confirmExtra = "confirm_extra"
        case maxWritesPerHour = "max_writes_per_hour"
        case agentMayConfirm = "agent_may_confirm"
        case revealGeneratedPasswords = "reveal_generated_passwords"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: PermissionLevel].self, forKey: .levels) ?? [:]
        var levels: [ResourceType: PermissionLevel] = [:]
        for (k, v) in raw {
            guard let r = ResourceType(rawValue: k) else {
                throw DecodingError.dataCorruptedError(forKey: .levels, in: c, debugDescription: "Unbekannte Ressource \(k)")
            }
            levels[r] = v
        }
        self.levels = levels
        domainPatterns = try c.decodeIfPresent([String].self, forKey: .domainPatterns) ?? []
        excludedTargets = try c.decodeIfPresent([String].self, forKey: .excludedTargets) ?? []
        scopes = try c.decodeIfPresent(PolicyScopes.self, forKey: .scopes) ?? PolicyScopes()
        confirmExtra = try c.decodeIfPresent([String].self, forKey: .confirmExtra) ?? []
        maxWritesPerHour = try c.decodeIfPresent(Int.self, forKey: .maxWritesPerHour)
        agentMayConfirm = try c.decodeIfPresent(Bool.self, forKey: .agentMayConfirm) ?? false
        revealGeneratedPasswords = try c.decodeIfPresent(Bool.self, forKey: .revealGeneratedPasswords) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: levels.map { ($0.key.rawValue, $0.value) }), forKey: .levels)
        try c.encode(domainPatterns, forKey: .domainPatterns)
        try c.encode(excludedTargets, forKey: .excludedTargets)
        try c.encode(scopes, forKey: .scopes)
        try c.encode(confirmExtra, forKey: .confirmExtra)
        try c.encodeIfPresent(maxWritesPerHour, forKey: .maxWritesPerHour)
        try c.encode(agentMayConfirm, forKey: .agentMayConfirm)
        try c.encode(revealGeneratedPasswords, forKey: .revealGeneratedPasswords)
    }
}

/// Ergebnis der Rechteprüfung. Effektives Recht = Policy ∩ Capability ∩ Scope.
public enum Authorization: Equatable, Sendable {
    case allowed
    case requiresConfirmation
    case deniedByPolicy(PermissionLevel, required: PermissionLevel)
    case unsupportedByProvider
    case outOfScope
}

/// Aktionen mit fester Bestätigungspflicht, unabhängig von der Rechtestufe.
public let confirmationRequired: Set<Capability> = [
    Capability(.mailbox, .delete),
    Capability(.domain, .delete),
    Capability(.subdomain, .delete),
    Capability(.dnsZone, .delete),
    Capability(.database, .delete),
    Capability(.subaccount, .create),
    Capability(.subaccount, .delete),
    Capability(.dkim, .create),
    Capability(.dkim, .delete),
    Capability(.server, .create),
    Capability(.server, .delete),
    Capability(.sshUser, .delete),
]

public struct PolicyEngine: Sendable {
    public init() {}

    public func authorize(
        _ capability: Capability,
        policy: Policy,
        matrix: CapabilityMatrix,
        target: String? = nil,
        recordType: String? = nil,
        extraConfirmations: Set<Capability> = []
    ) -> Authorization {
        guard matrix.supports(capability) else { return .unsupportedByProvider }

        let have = policy.level(for: capability.resource)
        var need = PermissionLevel.required(for: capability.action)
        var protectedRecord = false
        if capability.resource == .dnsRecord, let recordType, capability.action != .list, capability.action != .get {
            let type = recordType.uppercased()
            if DNSRecord.protectedTypes.contains(type) {
                need = .manage
                protectedRecord = true
            } else if !policy.scopes.dnsRecordTypes.isEmpty,
                      !policy.scopes.dnsRecordTypes.map({ $0.uppercased() }).contains(type) {
                return .outOfScope
            }
        }
        guard have >= need else { return .deniedByPolicy(have, required: need) }

        if let target, !policy.domainPatterns.isEmpty, !Self.matches(target, patterns: policy.domainPatterns) {
            return .outOfScope
        }
        if let target, policy.excludedTargets.contains(where: { $0.lowercased() == target.lowercased() }) {
            return .outOfScope
        }
        if protectedRecord || confirmationRequired.contains(capability)
            || extraConfirmations.contains(capability) || policy.extraConfirmations.contains(capability) {
            return .requiresConfirmation
        }
        return .allowed
    }

    /// Ziel gegen Domain-Muster prüfen. `*` erlaubt alles, `*.example.de` deckt die Domain, Subdomains und
    /// Adressen darunter ab, `example.de` nur die Domain selbst und Adressen `@example.de`.
    public static func matches(_ target: String, patterns: [String]) -> Bool {
        let host = target.split(separator: "@").last.map(String.init)?.lowercased() ?? target.lowercased()
        for pattern in patterns.map({ $0.lowercased() }) {
            if pattern == "*" { return true }
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(2))
                if host == suffix || host.hasSuffix("." + suffix) { return true }
            } else if host == pattern {
                return true
            }
        }
        return false
    }
}

/// Zusammenfassungen für die App, ohne Secrets.
public struct ConnectionSummary: Identifiable, Codable, Sendable {
    public let id: String
    public let provider: String
    public let label: String

    public init(id: String, provider: String, label: String) {
        self.id = id
        self.provider = provider
        self.label = label
    }
}

public struct PendingActionSummary: Identifiable, Codable, Sendable {
    public let id: String
    public let capability: Capability
    public let target: String
    public let client: String

    public init(id: String, capability: Capability, target: String, client: String) {
        self.id = id
        self.capability = capability
        self.target = target
        self.client = client
    }
}

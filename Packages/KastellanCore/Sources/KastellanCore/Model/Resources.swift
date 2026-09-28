import Foundation

// Kanonisches Ressourcenmodell (Konzept, Abschnitt 6). Feldnamen im JSON sind snake_case.
// Provider-Spezifisches liegt in `extra`, nie stillschweigend in Kernfeldern. Jede Ressource
// trägt `connection_id` und `provider_ref` (Original-Kennung beim Provider).

/// Provider-Spezifisches, das keine Entsprechung im Kernmodell hat.
public typealias Extra = [String: JSONValue]

/// Minimaler JSON-Wert für `extra` und Tool-Parameter.
public enum JSONValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unbekannter JSON-Wert") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }

    public var description: String {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): String(b)
        case .null: "null"
        case .array(let a): "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .object(let o): "{" + o.keys.sorted().map { "\($0): \(o[$0]!.description)" }.joined(separator: ", ") + "}"
        }
    }
}

/// Gemeinsame Kennung jeder Ressource.
public struct ResourceRef: Codable, Hashable, Sendable {
    public var connectionID: String
    public var providerRef: String

    public init(connectionID: String, providerRef: String) {
        self.connectionID = connectionID
        self.providerRef = providerRef
    }

    enum CodingKeys: String, CodingKey {
        case connectionID = "connection_id"
        case providerRef = "provider_ref"
    }
}

public struct Domain: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var fqdn: String
    public var status: String?
    public var nameservers: [String]
    public var dnsManagedHere: Bool
    public var mailManagedHere: Bool
    public var path: String?
    public var extra: Extra

    public var id: String { fqdn }

    public init(ref: ResourceRef, fqdn: String, status: String? = nil, nameservers: [String] = [],
                dnsManagedHere: Bool = false, mailManagedHere: Bool = false, path: String? = nil, extra: Extra = [:]) {
        self.ref = ref; self.fqdn = fqdn; self.status = status; self.nameservers = nameservers
        self.dnsManagedHere = dnsManagedHere; self.mailManagedHere = mailManagedHere; self.path = path; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, fqdn, status, nameservers, path, extra
        case dnsManagedHere = "dns_managed_here"
        case mailManagedHere = "mail_managed_here"
    }
}

public struct Subdomain: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var fqdn: String
    public var parent: String
    public var targetPath: String?
    public var redirect: String?
    public var extra: Extra

    public var id: String { fqdn }

    public init(ref: ResourceRef, fqdn: String, parent: String, targetPath: String? = nil, redirect: String? = nil, extra: Extra = [:]) {
        self.ref = ref; self.fqdn = fqdn; self.parent = parent; self.targetPath = targetPath; self.redirect = redirect; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, fqdn, parent, redirect, extra
        case targetPath = "target_path"
    }
}

public struct DNSZone: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var zone: String
    public var defaultTTL: Int?
    public var extra: Extra

    public var id: String { zone }

    public init(ref: ResourceRef, zone: String, defaultTTL: Int? = nil, extra: Extra = [:]) {
        self.ref = ref; self.zone = zone; self.defaultTTL = defaultTTL; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, zone, extra
        case defaultTTL = "ttl_default"
    }
}

public struct DNSRecord: Codable, Hashable, Sendable, Identifiable {
    /// Record-Typen, die als geschützt gelten (Änderung nur mit `manage` und Bestätigung).
    public static let protectedTypes: Set<String> = ["MX", "NS", "SOA"]

    public var ref: ResourceRef
    public var zone: String
    /// Name relativ zur Zone, `@` für die Zone selbst.
    public var name: String
    public var type: String
    public var content: String
    public var ttl: Int?
    public var priority: Int?
    public var extra: Extra

    public var id: String { "\(zone)/\(name)/\(type)/\(ref.providerRef)" }
    public var isProtected: Bool { Self.protectedTypes.contains(type.uppercased()) }

    public init(ref: ResourceRef, zone: String, name: String, type: String, content: String,
                ttl: Int? = nil, priority: Int? = nil, extra: Extra = [:]) {
        self.ref = ref; self.zone = zone; self.name = name; self.type = type.uppercased()
        self.content = content; self.ttl = ttl; self.priority = priority; self.extra = extra
    }
}

/// Änderung an einer Zone für `dns_record_apply` (Diff-Semantik, Konzept Abschnitt 6).
public enum DNSChange: Codable, Hashable, Sendable {
    case create(name: String, type: String, content: String, ttl: Int?, priority: Int?)
    case update(providerRef: String, content: String?, ttl: Int?, priority: Int?)
    case delete(providerRef: String)
}

public struct Mailbox: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var address: String
    public var quotaMB: Int?
    public var usedMB: Int?
    public var status: String?
    public var spamFilter: String?
    public var senderAliases: [String]
    public var copyTo: [String]
    public var extra: Extra

    public var id: String { address }
    public var localPart: String { String(address.split(separator: "@").first ?? "") }
    public var domainPart: String { String(address.split(separator: "@").last ?? "") }

    public init(ref: ResourceRef, address: String, quotaMB: Int? = nil, usedMB: Int? = nil, status: String? = nil,
                spamFilter: String? = nil, senderAliases: [String] = [], copyTo: [String] = [], extra: Extra = [:]) {
        self.ref = ref; self.address = address; self.quotaMB = quotaMB; self.usedMB = usedMB; self.status = status
        self.spamFilter = spamFilter; self.senderAliases = senderAliases; self.copyTo = copyTo; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, address, status, extra
        case quotaMB = "quota_mb"
        case usedMB = "used_mb"
        case spamFilter = "spam_filter"
        case senderAliases = "sender_aliases"
        case copyTo = "copy_to"
    }
}

/// Eingaben zum Anlegen oder Ändern. Passwort ist optional: fehlt es, erzeugt Kastellan eines.
public struct MailboxSpec: Codable, Hashable, Sendable {
    public var address: String
    public var password: String?
    public var quotaMB: Int?
    public var copyTo: [String]?
    public var senderAliases: [String]?
    public var extra: Extra

    public init(address: String, password: String? = nil, quotaMB: Int? = nil, copyTo: [String]? = nil,
                senderAliases: [String]? = nil, extra: Extra = [:]) {
        self.address = address; self.password = password; self.quotaMB = quotaMB
        self.copyTo = copyTo; self.senderAliases = senderAliases; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case address, password, extra
        case quotaMB = "quota_mb"
        case copyTo = "copy_to"
        case senderAliases = "sender_aliases"
    }
}

public struct MailForward: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case active, pendingVerification = "pending_verification", disabled }

    public var ref: ResourceRef
    public var address: String
    public var targets: [String]
    public var keepCopy: Bool
    public var status: Status
    public var extra: Extra

    public var id: String { address }

    public init(ref: ResourceRef, address: String, targets: [String], keepCopy: Bool = false, status: Status = .active, extra: Extra = [:]) {
        self.ref = ref; self.address = address; self.targets = targets; self.keepCopy = keepCopy; self.status = status; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, address, targets, status, extra
        case keepCopy = "keep_copy"
    }
}

public struct MailAutoresponder: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var address: String
    public var active: Bool
    public var subject: String?
    public var text: String
    public var from: Date?
    public var until: Date?
    public var extra: Extra

    public var id: String { address }

    public init(ref: ResourceRef, address: String, active: Bool, subject: String? = nil, text: String,
                from: Date? = nil, until: Date? = nil, extra: Extra = [:]) {
        self.ref = ref; self.address = address; self.active = active; self.subject = subject; self.text = text
        self.from = from; self.until = until; self.extra = extra
    }
}

public struct MailingList: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var address: String
    public var members: [String]
    public var moderated: Bool
    public var extra: Extra

    public var id: String { address }

    public init(ref: ResourceRef, address: String, members: [String] = [], moderated: Bool = false, extra: Extra = [:]) {
        self.ref = ref; self.address = address; self.members = members; self.moderated = moderated; self.extra = extra
    }
}

public struct DKIMKey: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var domain: String
    public var selector: String
    public var publicKey: String
    public var active: Bool
    public var validUntil: Date?
    public var extra: Extra

    public var id: String { "\(domain)/\(selector)" }

    /// Fertiger TXT-Record-Inhalt für `<selector>._domainkey.<domain>`.
    public var txtRecord: String { "v=DKIM1; k=rsa; p=\(publicKey)" }
    public var recordName: String { "\(selector)._domainkey" }

    public init(ref: ResourceRef, domain: String, selector: String, publicKey: String, active: Bool = true,
                validUntil: Date? = nil, extra: Extra = [:]) {
        self.ref = ref; self.domain = domain; self.selector = selector; self.publicKey = publicKey
        self.active = active; self.validUntil = validUntil; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, domain, selector, active, extra
        case publicKey = "public_key"
        case validUntil = "valid_until"
    }
}

public struct FTPUser: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var username: String
    public var homePath: String?
    public var status: String?
    public var extra: Extra

    public var id: String { username }

    public init(ref: ResourceRef, username: String, homePath: String? = nil, status: String? = nil, extra: Extra = [:]) {
        self.ref = ref; self.username = username; self.homePath = homePath; self.status = status; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, username, status, extra
        case homePath = "home_path"
    }
}

public struct SSHUser: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var username: String
    public var publicKeys: [String]
    public var extra: Extra

    public var id: String { username }

    public init(ref: ResourceRef, username: String, publicKeys: [String] = [], extra: Extra = [:]) {
        self.ref = ref; self.username = username; self.publicKeys = publicKeys; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, username, extra
        case publicKeys = "public_keys"
    }
}

public struct Database: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var name: String
    public var engine: String
    public var host: String?
    public var users: [String]
    public var comment: String?
    public var extra: Extra

    public var id: String { name }

    public init(ref: ResourceRef, name: String, engine: String = "mysql", host: String? = nil, users: [String] = [],
                comment: String? = nil, extra: Extra = [:]) {
        self.ref = ref; self.name = name; self.engine = engine; self.host = host; self.users = users; self.comment = comment; self.extra = extra
    }
}

public struct DatabaseUser: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var name: String
    public var database: String
    public var privileges: [String]
    public var extra: Extra

    public var id: String { name }

    public init(ref: ResourceRef, name: String, database: String, privileges: [String] = [], extra: Extra = [:]) {
        self.ref = ref; self.name = name; self.database = database; self.privileges = privileges; self.extra = extra
    }
}

public struct CronJob: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    /// Fünf Felder wie in crontab: Minute Stunde Tag Monat Wochentag.
    public var schedule: String
    public var url: String?
    public var command: String?
    public var comment: String?
    public var active: Bool
    public var extra: Extra

    public var id: String { ref.providerRef }

    public init(ref: ResourceRef, schedule: String, url: String? = nil, command: String? = nil, comment: String? = nil,
                active: Bool = true, extra: Extra = [:]) {
        self.ref = ref; self.schedule = schedule; self.url = url; self.command = command; self.comment = comment
        self.active = active; self.extra = extra
    }
}

public struct Certificate: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var hostname: String
    public var issuer: String?
    public var validUntil: Date?
    public var autoRenew: Bool?
    public var forceHTTPS: Bool?
    public var extra: Extra

    public var id: String { hostname }

    public init(ref: ResourceRef, hostname: String, issuer: String? = nil, validUntil: Date? = nil,
                autoRenew: Bool? = nil, forceHTTPS: Bool? = nil, extra: Extra = [:]) {
        self.ref = ref; self.hostname = hostname; self.issuer = issuer; self.validUntil = validUntil
        self.autoRenew = autoRenew; self.forceHTTPS = forceHTTPS; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, hostname, issuer, extra
        case validUntil = "valid_until"
        case autoRenew = "auto_renew"
        case forceHTTPS = "force_https"
    }
}

public struct DirectoryProtection: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var path: String
    public var users: [String]
    public var realm: String?
    public var extra: Extra

    public var id: String { path }

    public init(ref: ResourceRef, path: String, users: [String] = [], realm: String? = nil, extra: Extra = [:]) {
        self.ref = ref; self.path = path; self.users = users; self.realm = realm; self.extra = extra
    }
}

public struct Subaccount: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var login: String
    public var comment: String?
    public var extra: Extra

    public var id: String { login }

    public init(ref: ResourceRef, login: String, comment: String? = nil, extra: Extra = [:]) {
        self.ref = ref; self.login = login; self.comment = comment; self.extra = extra
    }
}

public struct Server: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var name: String
    /// running, off, starting, stopping, rebuilding, ...
    public var status: String
    public var ipv4: String?
    public var ipv6: String?
    public var type: String?
    public var location: String?
    public var image: String?
    public var labels: [String: String]
    public var createdAt: Date?
    public var extra: Extra

    public var id: String { ref.providerRef }

    public init(ref: ResourceRef, name: String, status: String, ipv4: String? = nil, ipv6: String? = nil, type: String? = nil,
                location: String? = nil, image: String? = nil, labels: [String: String] = [:], createdAt: Date? = nil, extra: Extra = [:]) {
        self.ref = ref; self.name = name; self.status = status; self.ipv4 = ipv4; self.ipv6 = ipv6; self.type = type
        self.location = location; self.image = image; self.labels = labels; self.createdAt = createdAt; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, name, status, ipv4, ipv6, type, location, image, labels, extra
        case createdAt = "created_at"
    }
}

/// Eingaben zum Anlegen eines Servers.
public struct ServerSpec: Codable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var image: String
    public var location: String?
    public var sshKeys: [String]
    public var labels: [String: String]
    public var extra: Extra

    public init(name: String, type: String, image: String, location: String? = nil, sshKeys: [String] = [], labels: [String: String] = [:], extra: Extra = [:]) {
        self.name = name; self.type = type; self.image = image; self.location = location; self.sshKeys = sshKeys; self.labels = labels; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case name, type, image, location, labels, extra
        case sshKeys = "ssh_keys"
    }
}

/// Zustandsänderung an einem Server. Aus- und Neustart sind bestätigungspflichtig.
public enum ServerPowerAction: String, Codable, Sendable, CaseIterable {
    case powerOn = "power_on", powerOff = "power_off", reboot, shutdown

    public var isDisruptive: Bool { self != .powerOn }
}

public struct FirewallRule: Codable, Hashable, Sendable {
    public var direction: String
    public var protocolName: String
    public var port: String?
    public var sources: [String]
    public var destinations: [String]
    public var description: String?

    public init(direction: String, protocolName: String, port: String? = nil, sources: [String] = [], destinations: [String] = [], description: String? = nil) {
        self.direction = direction; self.protocolName = protocolName; self.port = port; self.sources = sources; self.destinations = destinations; self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case direction, port, sources, destinations, description
        case protocolName = "protocol"
    }
}

public struct Firewall: Codable, Hashable, Sendable, Identifiable {
    public var ref: ResourceRef
    public var name: String
    public var rules: [FirewallRule]
    public var appliedTo: [String]
    public var labels: [String: String]
    public var extra: Extra

    public var id: String { ref.providerRef }

    public init(ref: ResourceRef, name: String, rules: [FirewallRule] = [], appliedTo: [String] = [], labels: [String: String] = [:], extra: Extra = [:]) {
        self.ref = ref; self.name = name; self.rules = rules; self.appliedTo = appliedTo; self.labels = labels; self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case ref, name, rules, labels, extra
        case appliedTo = "applied_to"
    }
}

/// Verbindung zu einem Provider-Account. Ohne Secrets, die liegen im Schlüsselbund.
public struct Connection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var profileID: String
    public var provider: String
    public var label: String
    /// Nicht geheime Einstellungen, etwa `kas_login` oder `account_id`.
    public var settings: [String: String]
    public var createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), profileID: String, provider: String, label: String,
                settings: [String: String] = [:], createdAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.provider = provider; self.label = label
        self.settings = settings; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, label, settings
        case profileID = "profile_id"
        case legacyContextID = "context_id"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? c.decode(String.self, forKey: .legacyContextID)
        provider = try c.decode(String.self, forKey: .provider)
        label = try c.decode(String.self, forKey: .label)
        settings = try c.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(profileID, forKey: .profileID); try c.encode(provider, forKey: .provider)
        try c.encode(label, forKey: .label); try c.encode(settings, forKey: .settings); try c.encode(createdAt, forKey: .createdAt)
    }
}

public struct HealthStatus: Codable, Hashable, Sendable {
    public var connectionID: String
    public var ok: Bool
    public var message: String
    public var checkedAt: Date

    public init(connectionID: String, ok: Bool, message: String, checkedAt: Date = Date()) {
        self.connectionID = connectionID; self.ok = ok; self.message = message; self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey {
        case ok, message
        case connectionID = "connection_id"
        case checkedAt = "checked_at"
    }
}

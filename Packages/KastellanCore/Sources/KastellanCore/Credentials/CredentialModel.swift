import Foundation

/// Wohin ein erzeugtes Passwort geht (Konzept-Erweiterung 2026-09-07).
public enum CredentialSinkKind: String, Codable, CaseIterable, Sendable {
    /// Nur im Tool-Ergebnis, nirgends gespeichert.
    case resultOnly = "result_only"
    case keychain
    case bitwarden
    case onepassword

    public var displayName: String {
        switch self {
        case .resultOnly: "Nur im Ergebnis"
        case .keychain: "macOS-Schlüsselbund"
        case .bitwarden: "Bitwarden"
        case .onepassword: "1Password"
        }
    }

    /// Tresore, die nur die App entsperren kann. Der MCP-Server übergibt dann an die App.
    public var needsApp: Bool { self == .bitwarden || self == .onepassword }
}

/// Ziel innerhalb des Tresors.
public struct CredentialTarget: Codable, Sendable, Equatable {
    public var folderID: String?
    public var folderName: String?
    public var organizationID: String?
    public var organizationName: String?
    public var collectionIDs: [String]
    public var collectionNames: [String]
    /// 1Password: Tresorname oder -ID.
    public var vault: String?

    public init(folderID: String? = nil, folderName: String? = nil, organizationID: String? = nil, organizationName: String? = nil,
                collectionIDs: [String] = [], collectionNames: [String] = [], vault: String? = nil) {
        self.folderID = folderID; self.folderName = folderName; self.organizationID = organizationID; self.organizationName = organizationName
        self.collectionIDs = collectionIDs; self.collectionNames = collectionNames; self.vault = vault
    }

    enum CodingKeys: String, CodingKey {
        case vault
        case folderID = "folder_id", folderName = "folder_name"
        case organizationID = "organization_id", organizationName = "organization_name"
        case collectionIDs = "collection_ids", collectionNames = "collection_names"
    }

    public var description: String {
        var parts: [String] = []
        if let o = organizationName ?? organizationID { parts.append("Organisation \(o)") }
        if !collectionNames.isEmpty { parts.append("Sammlung \(collectionNames.joined(separator: ", "))") }
        if let f = folderName ?? folderID { parts.append("Ordner \(f)") }
        if let v = vault { parts.append("Tresor \(v)") }
        return parts.joined(separator: ", ")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folderID = try c.decodeIfPresent(String.self, forKey: .folderID)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
        organizationID = try c.decodeIfPresent(String.self, forKey: .organizationID)
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName)
        collectionIDs = try c.decodeIfPresent([String].self, forKey: .collectionIDs) ?? []
        collectionNames = try c.decodeIfPresent([String].self, forKey: .collectionNames) ?? []
        vault = try c.decodeIfPresent(String.self, forKey: .vault)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encodeIfPresent(folderName, forKey: .folderName)
        try c.encodeIfPresent(organizationID, forKey: .organizationID)
        try c.encodeIfPresent(organizationName, forKey: .organizationName)
        try c.encode(collectionIDs, forKey: .collectionIDs)
        try c.encode(collectionNames, forKey: .collectionNames)
        try c.encodeIfPresent(vault, forKey: .vault)
    }

}

/// Einstellung je Profil: Ablageort und Ziel.
public struct CredentialDeliveryConfig: Codable, Sendable, Equatable {
    public var kind: CredentialSinkKind
    public var target: CredentialTarget

    public init(kind: CredentialSinkKind = .keychain, target: CredentialTarget = CredentialTarget()) {
        self.kind = kind; self.target = target
    }
}

/// Ein vollständiger Zugang: Passwort mit Benutzername und Dienst, wie ein Login-Eintrag im Passwort-Manager.
public struct CredentialRecord: Codable, Sendable, Equatable {
    public var title: String
    public var username: String
    public var password: String
    /// Dienst-Host, etwa `w00abcde.kasserver.com`; kann fehlen.
    public var host: String?
    /// URL-Schema für den Eintrag: imaps, ftp, sftp, mysql, ssh, https.
    public var scheme: String
    public var port: Int?
    public var notes: String
    public var resource: ResourceType
    public var identifier: String
    public var connectionID: String
    public var connectionLabel: String
    public var profileID: String
    public var createdAt: Date

    public init(title: String, username: String, password: String, host: String? = nil, scheme: String = "https", port: Int? = nil,
                notes: String = "", resource: ResourceType, identifier: String, connectionID: String, connectionLabel: String,
                profileID: String, createdAt: Date = Date()) {
        self.title = title; self.username = username; self.password = password; self.host = host; self.scheme = scheme; self.port = port
        self.notes = notes; self.resource = resource; self.identifier = identifier; self.connectionID = connectionID
        self.connectionLabel = connectionLabel; self.profileID = profileID; self.createdAt = createdAt
    }

    /// `imaps://host:993` oder nil ohne Host.
    public var url: String? {
        guard let host else { return nil }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// Notiz mit Kastellan-Metadaten, damit Einträge wiedererkennbar bleiben.
    public var fullNotes: String {
        var lines = [notes].filter { !$0.isEmpty }
        lines.append("kastellan.resource=\(resource.rawValue)/\(identifier)")
        lines.append("kastellan.connection=\(connectionLabel) (\(connectionID))")
        lines.append("kastellan.created=\(ISO8601DateFormatter().string(from: createdAt))")
        return lines.joined(separator: "\n")
    }

    /// Titel-Konvention: „Postfach info@example.de (All-Inkl privat)“.
    public static func title(for resource: ResourceType, identifier: String, connectionLabel: String) -> String {
        "\(resource.displayName) \(identifier) (\(connectionLabel))"
    }

    enum CodingKeys: String, CodingKey {
        case title, username, password, host, scheme, port, notes, resource, identifier
        case connectionID = "connection_id", connectionLabel = "connection_label", profileID = "profile_id", createdAt = "created_at"
    }
}

/// Ergebnis einer Ablage.
public enum CredentialDeliveryOutcome: Sendable, Equatable {
    /// Gespeichert, mit Beschreibung für das Tool-Ergebnis („Bitwarden, Ordner Hosting“).
    case stored(String)
    /// An die App übergeben, weil der Tresor nur dort entsperrt werden kann.
    case handedOff(String)
    /// Bewusst nicht gespeichert.
    case resultOnly
    /// Ablage fehlgeschlagen; das Passwort muss trotzdem zurückgegeben werden.
    case failed(String)
}

/// Ablageort, der einen Zugang speichern kann.
public protocol CredentialSink: Sendable {
    var kind: CredentialSinkKind { get }
    func store(_ record: CredentialRecord, target: CredentialTarget) async throws -> String
}

/// `credentials.json`: Ablage-Einstellung je Profil.
public actor CredentialSettingsStore {
    private let fileURL: URL
    private var configs: [String: CredentialDeliveryConfig] = [:]
    private var loaded = false

    public init(fileURL: URL = AppPaths.credentialsFile) {
        self.fileURL = fileURL
    }

    public func config(profileID: String) throws -> CredentialDeliveryConfig {
        try loadIfNeeded()
        return configs[profileID] ?? CredentialDeliveryConfig()
    }

    public func set(_ config: CredentialDeliveryConfig, profileID: String) throws {
        try loadIfNeeded()
        configs[profileID] = config
        try AtomicFile.write(JSONCoding.encoder.encode(configs), to: fileURL)
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        configs = try JSONCoding.decoder.decode([String: CredentialDeliveryConfig].self, from: Data(contentsOf: fileURL))
    }
}

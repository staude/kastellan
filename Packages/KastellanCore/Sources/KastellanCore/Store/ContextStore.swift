import Foundation

/// Profil (Privat, Beruflich, ...). Verbindungen und Client-Tokens gehören zu genau einem Profil,
/// ein Token sieht nur die Verbindungen seines Profils. Pro Profil ein MCP-Eintrag in Claude.
public struct KastellanProfile: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public var name: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }

    /// Kurzform für Dateinamen und MCP-Servernamen, etwa `beruflich`.
    public var slug: String { TokenStore.slug(name) }

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }
}

/// `profiles.json`. Beim ersten Start werden „Privat“ und „Beruflich“ angelegt.
public actor ProfileStore {
    public static let defaultNames = ["Privat", "Beruflich"]

    private let fileURL: URL
    private var profiles: [KastellanProfile] = []
    private var loaded = false

    public init(fileURL: URL = AppPaths.profilesFile) {
        self.fileURL = fileURL
    }

    public func list() throws -> [KastellanProfile] {
        try loadIfNeeded()
        return profiles
    }

    public func get(id: String) throws -> KastellanProfile? {
        try loadIfNeeded()
        return profiles.first { $0.id == id }
    }

    public func find(slug: String) throws -> KastellanProfile? {
        try loadIfNeeded()
        return profiles.first { $0.slug == TokenStore.slug(slug) }
    }

    @discardableResult
    public func create(name: String) throws -> KastellanProfile {
        try loadIfNeeded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TokenStore.slug(trimmed).isEmpty else { throw KastellanError.invalidArgument("Profilname ist leer") }
        guard !profiles.contains(where: { $0.slug == TokenStore.slug(trimmed) }) else {
            throw KastellanError.invalidArgument("Profil \(trimmed) existiert bereits")
        }
        let ctx = KastellanProfile(name: trimmed)
        profiles.append(ctx)
        try save()
        return ctx
    }

    public func rename(id: String, to name: String) throws {
        try loadIfNeeded()
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { throw KastellanError.notFound("Profil \(id)") }
        profiles[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save()
    }

    /// Löschen nur, wenn keine Verbindung und kein Token mehr darauf zeigen. Prüft der Aufrufer.
    public func delete(id: String) throws {
        try loadIfNeeded()
        profiles.removeAll { $0.id == id }
        try save()
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        if FileManager.default.fileExists(atPath: fileURL.path) {
            profiles = try JSONCoding.decoder.decode([KastellanProfile].self, from: Data(contentsOf: fileURL))
        } else {
            profiles = Self.defaultNames.map { KastellanProfile(name: $0) }
            try save()
        }
    }

    private func save() throws {
        try AtomicFile.write(JSONCoding.encoder.encode(profiles), to: fileURL)
    }
}

/// `connections.json`, ohne Secrets.
public actor ConnectionStore {
    private let fileURL: URL
    private var connections: [Connection] = []
    private var loaded = false

    public init(fileURL: URL = AppPaths.connectionsFile) {
        self.fileURL = fileURL
    }

    public func list(profileID: String? = nil) throws -> [Connection] {
        try loadIfNeeded()
        return profileID.map { id in connections.filter { $0.profileID == id } } ?? connections
    }

    public func get(id: String) throws -> Connection? {
        try loadIfNeeded()
        return connections.first { $0.id == id }
    }

    public func upsert(_ connection: Connection) throws {
        try loadIfNeeded()
        if let i = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[i] = connection
        } else {
            connections.append(connection)
        }
        try save()
    }

    public func delete(id: String) throws {
        try loadIfNeeded()
        connections.removeAll { $0.id == id }
        try save()
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        connections = try JSONCoding.decoder.decode([Connection].self, from: Data(contentsOf: fileURL))
    }

    private func save() throws {
        try AtomicFile.write(JSONCoding.encoder.encode(connections), to: fileURL)
    }
}

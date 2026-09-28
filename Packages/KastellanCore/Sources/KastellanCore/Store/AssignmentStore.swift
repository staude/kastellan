import Foundation

/// Zuordnung: welche Verbindung ist für eine Domain und einen Ressourcentyp zuständig.
/// Fall: Mail bei All-Inkl, DNS bei Cloudflare. `assignments.json` im Kastellan-Home, Regeln pro Profil.
public struct Assignment: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var profileID: String
    /// Domain-Muster wie in der Policy: `*`, `*.example.de`, `example.de`.
    public var domainPattern: String
    /// Leer = alle Ressourcentypen.
    public var resources: [ResourceType]
    public var connectionID: String

    public init(id: String = UUID().uuidString.lowercased(), profileID: String, domainPattern: String, resources: [ResourceType], connectionID: String) {
        self.id = id; self.profileID = profileID; self.domainPattern = domainPattern; self.resources = resources; self.connectionID = connectionID
    }

    public init(id: String = UUID().uuidString.lowercased(), profileID: String, domainPattern: String, resource: ResourceType?, connectionID: String) {
        self.init(id: id, profileID: profileID, domainPattern: domainPattern, resources: resource.map { [$0] } ?? [], connectionID: connectionID)
    }

    public func covers(_ resource: ResourceType?) -> Bool {
        guard let resource else { return true }
        return resources.isEmpty || resources.contains(resource)
    }

    enum CodingKeys: String, CodingKey {
        case id, resources
        case legacyResource = "resource"
        case profileID = "profile_id"
        case legacyContextID = "context_id"
        case domainPattern = "domain"
        case connectionID = "connection_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? c.decode(String.self, forKey: .legacyContextID)
        domainPattern = try c.decode(String.self, forKey: .domainPattern)
        if let list = try c.decodeIfPresent([ResourceType].self, forKey: .resources) {
            resources = list
        } else {
            resources = try c.decodeIfPresent(ResourceType.self, forKey: .legacyResource).map { [$0] } ?? []
        }
        connectionID = try c.decode(String.self, forKey: .connectionID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(profileID, forKey: .profileID); try c.encode(domainPattern, forKey: .domainPattern)
        try c.encode(resources, forKey: .resources); try c.encode(connectionID, forKey: .connectionID)
    }
}

public actor AssignmentStore {
    private let fileURL: URL
    private var items: [Assignment] = []
    private var loaded = false

    public init(fileURL: URL = AppPaths.assignmentsFile) {
        self.fileURL = fileURL
    }

    public func list(profileID: String? = nil) throws -> [Assignment] {
        try loadIfNeeded()
        return profileID.map { id in items.filter { $0.profileID == id } } ?? items
    }

    public func upsert(_ a: Assignment) throws {
        try loadIfNeeded()
        if let i = items.firstIndex(where: { $0.id == a.id }) { items[i] = a } else { items.append(a) }
        try save()
    }

    public func delete(id: String) throws {
        try loadIfNeeded()
        items.removeAll { $0.id == id }
        try save()
    }

    public func removeConnection(_ connectionID: String) throws {
        try loadIfNeeded()
        items.removeAll { $0.connectionID == connectionID }
        try save()
    }

    /// Zuständige Verbindung: spezifischere Muster gewinnen (exakter Name vor `*.x` vor `*`),
    /// Regeln mit Ressourcentyp vor Regeln ohne.
    public func resolve(profileID: String, domain: String, resource: ResourceType?) throws -> [Assignment] {
        try loadIfNeeded()
        let host = domain.split(separator: "@").last.map(String.init)?.lowercased() ?? domain.lowercased()
        let matching = items.filter { a in
            a.profileID == profileID
                && PolicyEngine.matches(host, patterns: [a.domainPattern])
                && a.covers(resource)
        }
        return matching.sorted { Self.rank($0, resource) < Self.rank($1, resource) }
    }

    private static func rank(_ a: Assignment, _ resource: ResourceType?) -> Int {
        var r = 0
        if a.domainPattern == "*" { r += 20 } else if a.domainPattern.hasPrefix("*.") { r += 10 }
        if a.resources.isEmpty { r += 1 }
        return r
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        items = try JSONCoding.decoder.decode([Assignment].self, from: Data(contentsOf: fileURL))
    }

    private func save() throws {
        try AtomicFile.write(JSONCoding.encoder.encode(items), to: fileURL)
    }
}

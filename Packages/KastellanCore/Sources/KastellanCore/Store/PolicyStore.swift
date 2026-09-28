import Foundation

/// Rechte eines Clients in einem Profil auf dessen Verbindungen: `policies/<profil>-<client>.json`.
public struct ClientPolicy: Codable, Sendable, Equatable {
    public var profile: String
    public var client: String
    public var connections: [String: Policy]

    public init(profile: String, client: String, connections: [String: Policy] = [:]) {
        self.profile = profile
        self.client = client
        self.connections = connections
    }

    enum CodingKeys: String, CodingKey { case profile, client, connections, legacyContext = "context" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? c.decode(String.self, forKey: .legacyContext)
        client = try c.decode(String.self, forKey: .client)
        connections = try c.decodeIfPresent([String: Policy].self, forKey: .connections) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profile, forKey: .profile); try c.encode(client, forKey: .client); try c.encode(connections, forKey: .connections)
    }
}

/// Erweiterte Policy-Felder (Konzept, Abschnitt 7). Ergänzt `Policy` um DNS-Typen,
/// zusätzliche Bestätigungen und ein Schreib-Limit.
extension Policy {
    public var dnsRecordTypes: [String] {
        get { scopes.dnsRecordTypes }
        set { scopes.dnsRecordTypes = newValue }
    }
}

public struct PolicyScopes: Codable, Sendable, Equatable {
    /// Erlaubte DNS-Record-Typen für `write`. Leer = alle nicht geschützten.
    public var dnsRecordTypes: [String] = []

    public init(dnsRecordTypes: [String] = []) {
        self.dnsRecordTypes = dnsRecordTypes
    }

    enum CodingKeys: String, CodingKey {
        case dnsRecordTypes = "record_types"
    }
}

public actor PolicyStore {
    private let directory: URL

    public init(directory: URL = AppPaths.policiesDirectory) {
        self.directory = directory
    }

    /// Alle vorhandenen Policy-Dateien, als (Profil-Slug, Client-Slug).
    public func all() throws -> [ClientPolicy] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }.sorted().map {
            try JSONCoding.decoder.decode(ClientPolicy.self, from: Data(contentsOf: directory.appendingPathComponent($0)))
        }
    }

    public func load(profile: String, client: String) throws -> ClientPolicy {
        let url = file(profile: profile, client: client)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ClientPolicy(profile: profile, client: client)
        }
        return try JSONCoding.decoder.decode(ClientPolicy.self, from: Data(contentsOf: url))
    }

    public func save(_ policy: ClientPolicy) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AtomicFile.write(JSONCoding.encoder.encode(policy), to: file(profile: policy.profile, client: policy.client))
    }

    public func policy(profile: String, client: String, connectionID: String) throws -> Policy {
        try load(profile: profile, client: client).connections[connectionID] ?? Policy()
    }

    public func set(_ policy: Policy, profile: String, client: String, connectionID: String) throws {
        var cp = try load(profile: profile, client: client)
        cp.connections[connectionID] = policy
        try save(cp)
    }

    public func removeConnection(_ connectionID: String) throws {
        for var cp in try all() where cp.connections.removeValue(forKey: connectionID) != nil {
            try save(cp)
        }
    }

    private func file(profile: String, client: String) -> URL {
        directory.appendingPathComponent("\(TokenStore.slug(profile))-\(TokenStore.slug(client)).json")
    }
}

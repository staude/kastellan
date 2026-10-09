import Foundation

/// Ein von der App ausgestelltes Token für einen MCP-Client (Claude Code, Claude Desktop, Skript).
/// Gespeichert wird nur der SHA-256-Hash. Das Klartext-Token sieht der Nutzer genau einmal.
public struct ClientToken: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let client: String
    public let profileID: String
    public let tokenHash: String
    public let createdAt: Date
    public var lastUsedAt: Date?
    public var revokedAt: Date?

    public var isRevoked: Bool { revokedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, client
        case profileID = "profile_id"
        case legacyContextID = "context_id"
        case tokenHash = "token_hash"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case revokedAt = "revoked_at"
    }

    public init(id: String, client: String, profileID: String, tokenHash: String, createdAt: Date, lastUsedAt: Date?, revokedAt: Date?) {
        self.id = id; self.client = client; self.profileID = profileID; self.tokenHash = tokenHash
        self.createdAt = createdAt; self.lastUsedAt = lastUsedAt; self.revokedAt = revokedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        client = try c.decode(String.self, forKey: .client)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? c.decode(String.self, forKey: .legacyContextID)
        tokenHash = try c.decode(String.self, forKey: .tokenHash)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        revokedAt = try c.decodeIfPresent(Date.self, forKey: .revokedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(client, forKey: .client); try c.encode(profileID, forKey: .profileID)
        try c.encode(tokenHash, forKey: .tokenHash); try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt); try c.encodeIfPresent(revokedAt, forKey: .revokedAt)
    }
}

public struct IssuedToken: Sendable {
    public let token: String
    public let record: ClientToken
}

/// tokens.json im Kastellan-Home. Actor, weil App und Tests nebenläufig zugreifen.
public actor TokenStore {
    public static let prefix = "kastellan"

    private let fileURL: URL
    private var tokens: [ClientToken] = []
    private var loaded = false

    public init(fileURL: URL = AppPaths.tokensFile) {
        self.fileURL = fileURL
    }

    public func list() throws -> [ClientToken] {
        try loadIfNeeded()
        return tokens
    }

    /// Erzeugt ein Token `kastellan_<client>_<48 hex>` und speichert nur den Hash.
    public func issue(client: String, profileID: String) throws -> IssuedToken {
        try loadIfNeeded()
        let slug = Self.slug(client)
        guard !slug.isEmpty else { throw KastellanError.invalidArgument("Client-Name ist leer") }
        let bytes = SecureRandom.bytes(24)
        let token = "\(Self.prefix)_\(slug)_" + bytes.map { String(format: "%02x", $0) }.joined()
        let record = ClientToken(id: UUID().uuidString.lowercased(), client: client, profileID: profileID,
                                 tokenHash: Self.hash(token), createdAt: Date(), lastUsedAt: nil, revokedAt: nil)
        tokens.append(record)
        try save()
        return IssuedToken(token: token, record: record)
    }

    /// Liefert den Datensatz zu einem Klartext-Token, wenn es existiert und nicht widerrufen ist.
    public func verify(_ token: String) throws -> ClientToken? {
        try loadIfNeeded()
        let hash = Self.hash(token)
        guard let index = tokens.firstIndex(where: { $0.tokenHash == hash && !$0.isRevoked }) else { return nil }
        tokens[index].lastUsedAt = Date()
        try save()
        return tokens[index]
    }

    public func revoke(id: String) throws {
        try loadIfNeeded()
        guard let index = tokens.firstIndex(where: { $0.id == id }) else {
            throw KastellanError.notFound("Token \(id)")
        }
        tokens[index].revokedAt = Date()
        try save()
    }

    // MARK: - Intern

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        tokens = try JSONCoding.decoder.decode([ClientToken].self, from: Data(contentsOf: fileURL))
    }

    private func save() throws {
        try AtomicFile.write(JSONCoding.encoder.encode(tokens), to: fileURL)
    }

    static func hash(_ token: String) -> String {
        Digest.sha256Hex(Data(token.utf8))
    }

    static func slug(_ client: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = client.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
        var out = ""
        for ch in lowered where allowed.contains(ch) {
            if ch == "-", out.last == "-" { continue }
            out.append(ch)
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

public enum KastellanError: Error, LocalizedError, Sendable, Equatable {
    case invalidArgument(String)
    case notFound(String)
    case unauthorized(String)
    case unsupported(String)
    case provider(String)
    case `internal`(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let m): "Ungültiges Argument: \(m)"
        case .notFound(let m): "Nicht gefunden: \(m)"
        case .unauthorized(let m): "Nicht erlaubt: \(m)"
        case .unsupported(let m): "Nicht unterstützt: \(m)"
        case .provider(let m): "Provider-Fehler: \(m)"
        case .internal(let m): "Interner Fehler: \(m)"
        }
    }
}

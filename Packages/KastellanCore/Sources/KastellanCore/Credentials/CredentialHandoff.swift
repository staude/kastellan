import Foundation

/// Übergabe an die App: Der MCP-Server kann Bitwarden und 1Password nicht entsperren. Er legt den Zugang
/// im Schlüsselbund zwischen (Passwort) und schreibt eine Beschreibung ohne Passwort nach
/// `credential-handoff/<id>.json`. Die App legt ihn im Tresor ab und räumt beides auf.
public struct CredentialHandoff: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public var record: CredentialRecord   // ohne Passwort gespeichert
    public var kind: CredentialSinkKind
    public var target: CredentialTarget
    public var createdAt: Date
    public var lastError: String?

    public init(id: String = UUID().uuidString.lowercased(), record: CredentialRecord, kind: CredentialSinkKind, target: CredentialTarget, createdAt: Date = Date()) {
        self.id = id; self.record = record; self.kind = kind; self.target = target; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, record, kind, target
        case createdAt = "created_at", lastError = "last_error"
    }

    public static func secretKey(_ id: String) -> String { "handoff/\(id)" }
}

public actor CredentialHandoffStore {
    private let directory: URL
    private let secrets: any SecretStore

    public init(directory: URL = AppPaths.handoffDirectory, secrets: any SecretStore) {
        self.directory = directory
        self.secrets = secrets
    }

    /// Legt eine Übergabe an: Passwort in den Schlüsselbund, Rest als Datei.
    public func create(_ record: CredentialRecord, kind: CredentialSinkKind, target: CredentialTarget) async throws -> CredentialHandoff {
        var stripped = record
        stripped.password = ""
        let handoff = CredentialHandoff(record: stripped, kind: kind, target: target)
        try await secrets.set(connectionID: "kastellan", key: CredentialHandoff.secretKey(handoff.id), value: record.password)
        try write(handoff)
        return handoff
    }

    public func list() throws -> [CredentialHandoff] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }.sorted().map {
            try JSONCoding.decoder.decode(CredentialHandoff.self, from: Data(contentsOf: directory.appendingPathComponent($0)))
        }
    }

    /// Vollständiger Datensatz inklusive Passwort aus dem Schlüsselbund.
    public func record(for handoff: CredentialHandoff) async throws -> CredentialRecord {
        guard let password = try await secrets.secret(connectionID: "kastellan", key: CredentialHandoff.secretKey(handoff.id)) else {
            throw KastellanError.notFound("Passwort der Übergabe \(handoff.id) fehlt im Schlüsselbund")
        }
        var full = handoff.record
        full.password = password
        return full
    }

    public func markFailed(_ handoff: CredentialHandoff, error: String) throws {
        var h = handoff
        h.lastError = error
        try write(h)
    }

    public func remove(_ handoff: CredentialHandoff) async throws {
        try? await secrets.delete(connectionID: "kastellan", key: CredentialHandoff.secretKey(handoff.id))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(handoff.id).json"))
    }

    private func write(_ h: CredentialHandoff) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try AtomicFile.write(JSONCoding.encoder.encode(h), to: directory.appendingPathComponent("\(h.id).json"))
    }
}

/// Entscheidet je Profil, wohin ein erzeugter Zugang geht, und führt die Ablage aus oder übergibt an die App.
public struct CredentialDeliverer: Sendable {
    public let settings: CredentialSettingsStore
    public let handoffs: CredentialHandoffStore
    public let keychain: KeychainCredentialSink
    /// Tresore, die dieser Prozess direkt bedienen kann (App mit entsperrter Session); der MCP-Server hat keine.
    public let directSinks: [CredentialSinkKind: any CredentialSink]

    public init(settings: CredentialSettingsStore, handoffs: CredentialHandoffStore, keychain: KeychainCredentialSink = KeychainCredentialSink(),
                directSinks: [CredentialSinkKind: any CredentialSink] = [:]) {
        self.settings = settings; self.handoffs = handoffs; self.keychain = keychain; self.directSinks = directSinks
    }

    public func deliver(_ record: CredentialRecord) async -> CredentialDeliveryOutcome {
        let config = (try? await settings.config(profileID: record.profileID)) ?? CredentialDeliveryConfig()
        switch config.kind {
        case .resultOnly:
            return .resultOnly
        case .keychain:
            do { return .stored(try await keychain.store(record, target: config.target)) } catch { return .failed(error.localizedDescription) }
        case .bitwarden, .onepassword:
            if let sink = directSinks[config.kind] {
                do { return .stored(try await sink.store(record, target: config.target)) } catch { return .failed(error.localizedDescription) }
            }
            do {
                _ = try await handoffs.create(record, kind: config.kind, target: config.target)
                let target = config.target.description
                return .handedOff("\(config.kind.displayName)\(target.isEmpty ? "" : " (\(target))"), wird von der Kastellan-App abgelegt, sobald der Tresor entsperrt ist")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Text und Passwortfeld für das Tool-Ergebnis.
    public static func resultFields(outcome: CredentialDeliveryOutcome, password: String, reveal: Bool) -> [String: JSONValue] {
        switch outcome {
        case .resultOnly:
            return ["password": .string(password), "password_storage": .string("nicht gespeichert (Ablage: nur im Ergebnis)")]
        case .stored(let where_):
            return ["password": reveal ? .string(password) : .string("gespeichert"), "password_storage": .string(where_)]
        case .handedOff(let where_):
            return ["password": reveal ? .string(password) : .string("wird abgelegt"), "password_storage": .string(where_)]
        case .failed(let why):
            return ["password": .string(password), "password_storage": .string("Ablage fehlgeschlagen: \(why). Passwort nur hier.")]
        }
    }
}

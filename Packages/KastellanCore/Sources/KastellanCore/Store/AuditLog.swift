import Foundation

/// Eine Zeile in `audit.jsonl` (Konzept, Abschnitt 11). Keine Secrets, keine Parameter mit Passwörtern.
public struct AuditEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case ok, denied, unsupported, outOfScope = "out_of_scope", pending, confirmed, cancelled, error
    }

    public var id: String
    public var timestamp: Date
    public var client: String
    public var connectionID: String?
    /// Aufgerufenes Tool oder Befehl, etwa `mailbox_list` oder `kastellan_get_policy`.
    public var tool: String?
    /// Ressource und Aktion, fehlt bei Meta-Tools ohne Ressourcenbezug.
    public var capability: Capability?
    public var target: String?
    public var outcome: Outcome
    public var message: String?
    /// Provider-Aufruf (nur Funktionsname), etwa `add_mailaccount`.
    public var providerCall: String?
    public var durationMS: Int?
    public var pendingActionID: String?

    public init(id: String = UUID().uuidString.lowercased(), timestamp: Date = Date(), client: String, connectionID: String? = nil,
                tool: String? = nil, capability: Capability? = nil, target: String? = nil, outcome: Outcome, message: String? = nil,
                providerCall: String? = nil, durationMS: Int? = nil, pendingActionID: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.client = client; self.connectionID = connectionID
        self.tool = tool; self.capability = capability; self.target = target; self.outcome = outcome; self.message = message
        self.providerCall = providerCall; self.durationMS = durationMS; self.pendingActionID = pendingActionID
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, client, tool, capability, target, outcome, message
        case connectionID = "connection_id"
        case providerCall = "provider_call"
        case durationMS = "duration_ms"
        case pendingActionID = "pending_action_id"
    }
}

public struct AuditFilter: Sendable {
    public var client: String?
    public var connectionID: String?
    public var since: Date?
    public var outcome: AuditEntry.Outcome?
    public var limit: Int

    public init(client: String? = nil, connectionID: String? = nil, since: Date? = nil, outcome: AuditEntry.Outcome? = nil, limit: Int = 500) {
        self.client = client; self.connectionID = connectionID; self.since = since; self.outcome = outcome; self.limit = limit
    }
}

/// Append-only JSONL. Jede Zeile wird mit einem einzigen write(2) im O_APPEND-Modus geschrieben,
/// damit App und kastellan-mcp gleichzeitig loggen können, ohne Zeilen zu vermischen.
public struct AuditLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AppPaths.auditFile) {
        self.fileURL = fileURL
    }

    public func append(_ entry: AuditEntry) throws {
        var line = try Self.lineEncoder.encode(entry)
        line.append(0x0A)
        try Self.appendLine(line, to: fileURL)
    }

    public func entries(_ filter: AuditFilter = AuditFilter()) throws -> [AuditEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var result: [AuditEntry] = []
        for chunk in data.split(separator: 0x0A) {
            guard let e = try? JSONCoding.decoder.decode(AuditEntry.self, from: chunk) else { continue }
            if let c = filter.client, e.client != c { continue }
            if let id = filter.connectionID, e.connectionID != id { continue }
            if let s = filter.since, e.timestamp < s { continue }
            if let o = filter.outcome, e.outcome != o { continue }
            result.append(e)
        }
        return Array(result.suffix(filter.limit))
    }

    /// Anzahl schreibender Aktionen eines Clients auf einer Verbindung im Zeitraum (für max_writes_per_hour).
    public func writeCount(client: String, connectionID: String, since: Date) throws -> Int {
        try entries(AuditFilter(client: client, connectionID: connectionID, since: since, limit: .max))
            .filter { $0.outcome == .ok && $0.capability != nil && $0.capability?.action != .list && $0.capability?.action != .get }
            .count
    }

    static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func appendLine(_ line: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(Windows)
        // Windows: kein POSIX-open mit Rechten; Anhängen über FileHandle genügt (eine Zeile je Aufruf).
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        #else
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw KastellanError.internal("Audit-Log öffnen: errno \(errno)") }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw KastellanError.internal("Audit-Log schreiben: \(written) von \(line.count) Bytes") }
        #endif
    }
}

/// `health.jsonl`: ein Eintrag pro Prüfung, der letzte pro Verbindung zählt.
public struct HealthLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AppPaths.healthFile) {
        self.fileURL = fileURL
    }

    public func append(_ status: HealthStatus) throws {
        var line = try AuditLog.lineEncoder.encode(status)
        line.append(0x0A)
        try AuditLog.appendLine(line, to: fileURL)
    }

    public func latest() throws -> [String: HealthStatus] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        var result: [String: HealthStatus] = [:]
        for chunk in data.split(separator: 0x0A) {
            if let s = try? JSONCoding.decoder.decode(HealthStatus.self, from: chunk) {
                result[s.connectionID] = s
            }
        }
        return result
    }
}

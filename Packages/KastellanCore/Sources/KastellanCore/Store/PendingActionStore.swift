import Foundation

/// Bestätigungspflichtige Aktion (Konzept, Abschnitt 5 und 9). Liegt als `pending/<id>.json`.
/// kastellan-mcp legt sie an, die App gibt frei und führt aus, das MCP-Tool fragt das Ergebnis ab.
public struct PendingAction: Codable, Identifiable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case prepared, confirmed, executing, done, failed, cancelled

        public var isFinal: Bool { self == .done || self == .failed || self == .cancelled }
    }

    public let id: String
    public let client: String
    public let connectionID: String
    public let capability: Capability
    public let target: String
    public let parameters: [String: JSONValue]
    /// Menschenlesbare Vorschau, was passieren wird.
    public let preview: String
    public var status: Status
    public let createdAt: Date
    public var decidedAt: Date?
    public var finishedAt: Date?
    public var result: JSONValue?
    public var error: String?

    public init(id: String = UUID().uuidString.lowercased(), client: String, connectionID: String, capability: Capability,
                target: String, parameters: [String: JSONValue] = [:], preview: String, status: Status = .prepared,
                createdAt: Date = Date()) {
        self.id = id; self.client = client; self.connectionID = connectionID; self.capability = capability
        self.target = target; self.parameters = parameters; self.preview = preview; self.status = status; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, client, capability, target, parameters, preview, status, result, error
        case connectionID = "connection_id"
        case createdAt = "created_at"
        case decidedAt = "decided_at"
        case finishedAt = "finished_at"
    }
}

/// Dateibasierter Store. Jede Änderung ist ein atomares Rename, deshalb können App und MCP
/// gleichzeitig zugreifen. Zustandsübergänge sind fest: prepared → confirmed → executing → done|failed,
/// prepared|confirmed → cancelled.
public actor PendingActionStore {
    private let directory: URL

    public init(directory: URL = AppPaths.pendingDirectory) {
        self.directory = directory
    }

    public func create(_ action: PendingAction) throws -> PendingAction {
        try write(action)
        return action
    }

    public func get(id: String) throws -> PendingAction? {
        let url = file(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONCoding.decoder.decode(PendingAction.self, from: Data(contentsOf: url))
    }

    public func list(includeFinal: Bool = false) throws -> [PendingAction] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }
            .compactMap { try get(id: String($0.dropLast(5))) }
            .filter { includeFinal || !$0.status.isFinal }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func transition(id: String, to status: PendingAction.Status, result: JSONValue? = nil, error: String? = nil) throws -> PendingAction {
        guard var action = try get(id: id) else { throw KastellanError.notFound("Pending Action \(id)") }
        guard Self.allowed(from: action.status, to: status) else {
            throw KastellanError.invalidArgument("Übergang \(action.status.rawValue) → \(status.rawValue) nicht erlaubt")
        }
        action.status = status
        switch status {
        case .confirmed, .cancelled: action.decidedAt = Date()
        case .done, .failed: action.finishedAt = Date()
        default: break
        }
        if let result { action.result = result }
        if let error { action.error = error }
        try write(action)
        return action
    }

    /// Entfernt abgeschlossene Aktionen, die älter als `olderThan` sind.
    public func purge(olderThan interval: TimeInterval) throws -> Int {
        var removed = 0
        for action in try list(includeFinal: true) where action.status.isFinal {
            let stamp = action.finishedAt ?? action.decidedAt ?? action.createdAt
            if Date().timeIntervalSince(stamp) > interval {
                try FileManager.default.removeItem(at: file(action.id))
                removed += 1
            }
        }
        return removed
    }

    static func allowed(from: PendingAction.Status, to: PendingAction.Status) -> Bool {
        switch (from, to) {
        case (.prepared, .confirmed), (.prepared, .cancelled),
             (.confirmed, .executing), (.confirmed, .cancelled),
             (.executing, .done), (.executing, .failed):
            true
        default:
            false
        }
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    private func write(_ action: PendingAction) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AtomicFile.write(JSONCoding.encoder.encode(action), to: file(action.id))
    }
}

import Foundation

/// Anfrage eines Clients an Kastellan.
public struct ActionRequest: Sendable {
    public var client: String
    public var profile: KastellanProfile
    public var connectionID: String
    public var capability: Capability
    /// Ziel der Aktion, etwa eine Adresse, ein Hostname oder eine Zone (für Scope und Audit).
    public var target: String?
    public var recordType: String?
    public var parameters: [String: JSONValue]
    /// Menschenlesbare Vorschau für die Freigabe.
    public var preview: String

    public init(client: String, profile: KastellanProfile, connectionID: String, capability: Capability, target: String? = nil,
                recordType: String? = nil, parameters: [String: JSONValue] = [:], preview: String = "") {
        self.client = client; self.profile = profile; self.connectionID = connectionID; self.capability = capability
        self.target = target; self.recordType = recordType; self.parameters = parameters; self.preview = preview
    }
}

public enum ActionOutcome: Sendable {
    case done(JSONValue)
    case pending(PendingAction)
}

/// Bündelt alle Stores und Adapter. App und kastellan-mcp erzeugen je eine Instanz.
public struct Runtime: Sendable {
    public let profiles: ProfileStore
    public let connections: ConnectionStore
    public let assignments: AssignmentStore
    public let tokens: TokenStore
    public let policies: PolicyStore
    public let pending: PendingActionStore
    public let audit: AuditLog
    public let health: HealthLog
    public let secrets: any SecretStore
    public let registry: AdapterRegistry
    public let credentialSettings: CredentialSettingsStore
    public let handoffs: CredentialHandoffStore
    /// Tresore, die dieser Prozess direkt bedienen kann (App nach Entsperren). Der MCP-Server lässt das leer.
    public var directSinks: [CredentialSinkKind: any CredentialSink] = [:]

    public init(profiles: ProfileStore = ProfileStore(), connections: ConnectionStore = ConnectionStore(),
                assignments: AssignmentStore = AssignmentStore(),
                tokens: TokenStore = TokenStore(), policies: PolicyStore = PolicyStore(),
                pending: PendingActionStore = PendingActionStore(), audit: AuditLog = AuditLog(),
                health: HealthLog = HealthLog(), secrets: any SecretStore = KeychainSecretStore(),
                registry: AdapterRegistry = AdapterRegistry(), credentialSettings: CredentialSettingsStore? = nil,
                handoffs: CredentialHandoffStore? = nil) {
        self.profiles = profiles; self.connections = connections; self.assignments = assignments; self.tokens = tokens; self.policies = policies
        self.pending = pending; self.audit = audit; self.health = health; self.secrets = secrets; self.registry = registry
        self.credentialSettings = credentialSettings ?? CredentialSettingsStore()
        self.handoffs = handoffs ?? CredentialHandoffStore(secrets: secrets)
    }

    public var deliverer: CredentialDeliverer {
        CredentialDeliverer(settings: credentialSettings, handoffs: handoffs, directSinks: directSinks)
    }

    /// Runtime im Kastellan-Home mit allen eingebauten Adaptern.
    public static func standard(registry: AdapterRegistry, secrets: any SecretStore = KeychainSecretStore()) throws -> Runtime {
        try AppPaths.ensureDirectories()
        return Runtime(secrets: secrets, registry: registry)
    }

    public func adapter(for connectionID: String) async throws -> any ProviderAdapter {
        guard let connection = try await connections.get(id: connectionID) else {
            throw KastellanError.notFound("Verbindung \(connectionID)")
        }
        return try registry.adapter(for: connection, secrets: secrets)
    }
}

/// Führt eine Aktion aus: Rechteprüfung (Policy ∩ Capability ∩ Scope), Schreib-Limit, Ausführung über
/// den Adapter oder Ablage als Pending Action. Jeder Schritt landet im Audit.
public struct ActionExecutor: Sendable {
    public typealias Operation = @Sendable (any ProviderAdapter) async throws -> JSONValue

    public let runtime: Runtime
    private let engine = PolicyEngine()

    public init(runtime: Runtime) {
        self.runtime = runtime
    }

    /// Prüft, ob eine Aktion erlaubt wäre, ohne sie auszuführen. Für Tool-Listen und Vorschauen.
    public func authorize(_ request: ActionRequest) async throws -> Authorization {
        guard let connection = try await runtime.connections.get(id: request.connectionID) else {
            throw KastellanError.notFound("Verbindung \(request.connectionID)")
        }
        guard connection.profileID == request.profile.id else {
            return .outOfScope
        }
        guard let matrix = runtime.registry.capabilityMatrix(for: connection.provider) else {
            return .unsupportedByProvider
        }
        let policy = try await runtime.policies.policy(profile: request.profile.slug, client: request.client, connectionID: connection.id)
        return engine.authorize(request.capability, policy: policy, matrix: matrix, target: request.target, recordType: request.recordType)
    }

    /// Führt aus oder legt eine Pending Action an.
    public func perform(_ request: ActionRequest, operation: @escaping Operation) async throws -> ActionOutcome {
        let started = Date()
        let auth = try await authorize(request)
        switch auth {
        case .deniedByPolicy(let have, let need):
            try log(request, .denied, message: "Stufe \(have.rawValue), nötig \(need.rawValue)")
            throw KastellanError.unauthorized("\(request.capability) braucht Stufe \(need.rawValue), erlaubt ist \(have.rawValue)")
        case .unsupportedByProvider:
            try log(request, .unsupported)
            throw KastellanError.unsupported("\(request.capability) kann dieser Provider nicht")
        case .outOfScope:
            try log(request, .outOfScope, message: request.target)
            throw KastellanError.unauthorized("\(request.target ?? "Ziel") liegt außerhalb des erlaubten Bereichs")
        case .requiresConfirmation:
            let action = try await runtime.pending.create(PendingAction(
                client: request.client, connectionID: request.connectionID, capability: request.capability,
                target: request.target ?? "", parameters: request.parameters, preview: request.preview))
            try log(request, .pending, pendingActionID: action.id)
            return .pending(action)
        case .allowed:
            try await enforceWriteLimit(request)
            do {
                let adapter = try await runtime.adapter(for: request.connectionID)
                let result = try await operation(adapter)
                try log(request, .ok, durationMS: Self.ms(since: started))
                return .done(result)
            } catch {
                try log(request, .error, message: error.localizedDescription, durationMS: Self.ms(since: started))
                await Telemetry.shared.capture(error, tags: ["capability": request.capability.description, "client": request.client])
                throw error
            }
        }
    }

    /// Führt eine freigegebene Pending Action aus (App nach Klick auf „Freigeben“, oder Agent mit agent_may_confirm).
    public func execute(pendingID: String, by confirmer: String, operation: @escaping Operation) async throws -> PendingAction {
        guard let action = try await runtime.pending.get(id: pendingID) else {
            throw KastellanError.notFound("Pending Action \(pendingID)")
        }
        guard action.status == .prepared || action.status == .confirmed else {
            throw KastellanError.invalidArgument("Pending Action \(pendingID) ist \(action.status.rawValue)")
        }
        if action.status == .prepared {
            _ = try await runtime.pending.transition(id: pendingID, to: .confirmed)
        }
        _ = try await runtime.pending.transition(id: pendingID, to: .executing)
        let started = Date()
        let cap = action.capability
        do {
            let adapter = try await runtime.adapter(for: action.connectionID)
            let result = try await operation(adapter)
            let done = try await runtime.pending.transition(id: pendingID, to: .done, result: result)
            try runtime.audit.append(AuditEntry(client: action.client, connectionID: action.connectionID, capability: cap, target: action.target,
                                                outcome: .confirmed, message: "freigegeben von \(confirmer)", durationMS: Self.ms(since: started), pendingActionID: pendingID))
            return done
        } catch {
            await Telemetry.shared.capture(error, tags: ["capability": cap.description, "client": action.client, "phase": "approval"])
            let failed = try await runtime.pending.transition(id: pendingID, to: .failed, error: error.localizedDescription)
            try runtime.audit.append(AuditEntry(client: action.client, connectionID: action.connectionID, capability: cap, target: action.target,
                                                outcome: .error, message: error.localizedDescription, durationMS: Self.ms(since: started), pendingActionID: pendingID))
            return failed
        }
    }

    public func cancel(pendingID: String, by who: String) async throws -> PendingAction {
        let action = try await runtime.pending.transition(id: pendingID, to: .cancelled)
        try runtime.audit.append(AuditEntry(client: action.client, connectionID: action.connectionID, capability: action.capability,
                                            target: action.target, outcome: .cancelled, message: "verworfen von \(who)", pendingActionID: pendingID))
        return action
    }

    // MARK: - Intern

    private func enforceWriteLimit(_ request: ActionRequest) async throws {
        guard request.capability.action != .list, request.capability.action != .get else { return }
        let policy = try await runtime.policies.policy(profile: request.profile.slug, client: request.client, connectionID: request.connectionID)
        guard let limit = policy.maxWritesPerHour else { return }
        let count = try runtime.audit.writeCount(client: request.client, connectionID: request.connectionID, since: Date(timeIntervalSinceNow: -3600))
        if count >= limit {
            try log(request, .denied, message: "Schreib-Limit \(limit)/h erreicht")
            throw KastellanError.unauthorized("Schreib-Limit von \(limit) Aktionen pro Stunde erreicht")
        }
    }

    private func log(_ request: ActionRequest, _ outcome: AuditEntry.Outcome, message: String? = nil,
                     durationMS: Int? = nil, pendingActionID: String? = nil) throws {
        try runtime.audit.append(AuditEntry(client: request.client, connectionID: request.connectionID,
                                            tool: ActionCatalog.spec(for: request.capability)?.name, capability: request.capability,
                                            target: request.target, outcome: outcome, message: message,
                                            durationMS: durationMS, pendingActionID: pendingActionID))
    }

    private static func ms(since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
}

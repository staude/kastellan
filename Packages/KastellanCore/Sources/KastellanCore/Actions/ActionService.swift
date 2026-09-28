import Foundation

/// Verbindet Katalog, Executor und Stores: ein Aufruf eines Clients von der Eingabe bis zum Ergebnis.
/// Nutzen kastellan-mcp (Tool-Aufrufe) und die App (Freigaben).
public struct ActionService: Sendable {
    public let runtime: Runtime
    public let executor: ActionExecutor

    public init(runtime: Runtime) {
        self.runtime = runtime
        self.executor = ActionExecutor(runtime: runtime)
    }

    /// Welche Aktionen dieser Client in seinem Profil überhaupt sehen darf: mindestens eine Verbindung
    /// erlaubt die Stufe und der Provider kann die Ressource.
    public func visibleSpecs(client: String, profile: KastellanProfile) async throws -> [ActionSpec] {
        let connections = try await runtime.connections.list(profileID: profile.id)
        var visible: [ActionSpec] = []
        for spec in ActionCatalog.all {
            let need = PermissionLevel.required(for: spec.capability.action)
            var ok = false
            for c in connections {
                guard let matrix = runtime.registry.capabilityMatrix(for: c.provider), matrix.supports(spec.capability) else { continue }
                let policy = try await runtime.policies.policy(profile: profile.slug, client: client, connectionID: c.id)
                if policy.level(for: spec.capability.resource) >= need { ok = true; break }
            }
            if ok { visible.append(spec) }
        }
        return visible
    }

    /// Verbindung für einen Aufruf ohne `connection_id` über die Zuordnung ermitteln. Eindeutig oder Fehler.
    public func resolveConnection(for spec: ActionSpec, input: ActionInput, client: String, profile: KastellanProfile) async throws -> String {
        if let given = input.optionalString("connection_id") { return given }
        let target = input.optionalString("address") ?? input.optionalString("domain") ?? input.optionalString("zone")
            ?? input.optionalString("fqdn") ?? input.optionalString("hostname") ?? input.optionalString("parent")
        guard let target else {
            throw KastellanError.invalidArgument("connection_id fehlt (siehe kastellan_list_connections)")
        }
        // Zuordnungsregeln in Rangfolge: die genaueste nutzbare Regel gewinnt (exakter Name vor *.x vor *,
        // Regel mit Ressourcen vor Regel ohne). Erst wenn keine Regel greift, der Rückfall über die Policy.
        let matches = try await runtime.assignments.resolve(profileID: profile.id, domain: target, resource: spec.capability.resource)
        for a in matches {
            let usable = try await filterUsable([a.connectionID], spec: spec, client: client, profile: profile)
            if let id = usable.first { return id }
        }
        let candidates: [String] = []
        switch candidates.count {
        case 1: return candidates[0]
        case 0:
            // Rückfall: genau eine Verbindung im Profil, die die Ressource kann und deren Policy das Ziel erlaubt.
            let all = try await runtime.connections.list(profileID: profile.id).map(\.id)
            let usable = try await filterUsable(all, spec: spec, client: client, profile: profile, target: target)
            guard usable.count == 1 else {
                throw KastellanError.invalidArgument("connection_id fehlt und keine eindeutige Zuordnung für \(target) (\(spec.capability.resource.rawValue)). Zuordnung in der App anlegen oder connection_id angeben.")
            }
            return usable[0]
        default:
            throw KastellanError.invalidArgument("Mehrere Verbindungen für \(target): \(candidates.joined(separator: ", ")). connection_id angeben.")
        }
    }

    private func filterUsable(_ ids: [String], spec: ActionSpec, client: String, profile: KastellanProfile, target: String? = nil) async throws -> [String] {
        var out: [String] = []
        for id in ids {
            guard let c = try await runtime.connections.get(id: id), c.profileID == profile.id,
                  let matrix = runtime.registry.capabilityMatrix(for: c.provider), matrix.supports(spec.capability) else { continue }
            let policy = try await runtime.policies.policy(profile: profile.slug, client: client, connectionID: id)
            guard policy.level(for: spec.capability.resource) >= PermissionLevel.required(for: spec.capability.action) else { continue }
            if let target, !policy.domainPatterns.isEmpty, !PolicyEngine.matches(target, patterns: policy.domainPatterns) { continue }
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// Führt eine Aktion des Katalogs aus.
    public func call(_ specName: String, input: [String: JSONValue], client: String, profile: KastellanProfile) async throws -> ActionOutcome {
        guard let spec = ActionCatalog.spec(named: specName) else { throw KastellanError.notFound("Aktion \(specName)") }
        var values = ActionInput(input)
        let connectionID = try await resolveConnection(for: spec, input: values, client: client, profile: profile)
        var input = input
        input["connection_id"] = .string(connectionID)
        values = ActionInput(input)
        let policy = try await runtime.policies.policy(profile: profile.slug, client: client, connectionID: connectionID)
        let label = try await runtime.connections.get(id: connectionID)?.label ?? connectionID
        let prepared = try spec.build(values, ActionContext(connectionID: connectionID, connectionLabel: label, profileID: profile.id, secrets: runtime.secrets,
                                                              revealGeneratedPasswords: policy.revealGeneratedPasswords, deliverer: runtime.deliverer))
        let request = ActionRequest(client: client, profile: profile, connectionID: connectionID, capability: spec.capability,
                                    target: prepared.target, recordType: prepared.recordType, parameters: Self.storable(input), preview: prepared.preview)
        if spec.prepares || prepared.requiresConfirmation {
            // Immer als Pending Action, auch wenn die Stufe reichen würde. Rechte werden trotzdem geprüft.
            let auth = try await executor.authorize(request)
            switch auth {
            case .allowed, .requiresConfirmation:
                let action = try await runtime.pending.create(PendingAction(
                    client: client, connectionID: connectionID, capability: spec.capability, target: prepared.target ?? "",
                    parameters: request.parameters, preview: prepared.preview))
                try runtime.audit.append(AuditEntry(client: client, connectionID: connectionID, capability: spec.capability, target: prepared.target,
                                                    outcome: .pending, pendingActionID: action.id))
                return .pending(action)
            default:
                break // Ablehnung mit Audit übernimmt perform()
            }
        }
        return try await executor.perform(request, operation: prepared.operation)
    }

    /// Freigabe einer Pending Action: Operation aus Katalog und gespeicherten Parametern neu bauen und ausführen.
    /// `asAgent` = Aufruf über MCP; dann muss die Policy `agent_may_confirm` erlauben und der Client muss
    /// derselbe sein, der die Aktion vorbereitet hat.
    public func approve(pendingID: String, by who: String, asAgent: Bool = false) async throws -> PendingAction {
        guard let action = try await runtime.pending.get(id: pendingID) else { throw KastellanError.notFound("Pending Action \(pendingID)") }
        guard let spec = ActionCatalog.spec(for: action.capability) else {
            throw KastellanError.internal("Keine Aktion für \(action.capability)")
        }
        guard let connection = try await runtime.connections.get(id: action.connectionID),
              let profile = try await runtime.profiles.get(id: connection.profileID) else {
            throw KastellanError.notFound("Verbindung \(action.connectionID)")
        }
        let policy = try await runtime.policies.policy(profile: profile.slug, client: action.client, connectionID: action.connectionID)
        if asAgent {
            guard who == action.client else { throw KastellanError.unauthorized("Pending Action gehört Client \(action.client)") }
            guard policy.agentMayConfirm else {
                throw KastellanError.unauthorized("Freigabe nur in der Kastellan-App (agent_may_confirm ist aus)")
            }
        }
        let prepared = try spec.build(ActionInput(action.parameters), ActionContext(connectionID: action.connectionID, connectionLabel: connection.label, profileID: profile.id,
                                                                                  secrets: runtime.secrets, revealGeneratedPasswords: policy.revealGeneratedPasswords,
                                                                                  deliverer: runtime.deliverer))
        return try await executor.execute(pendingID: pendingID, by: who, operation: prepared.operation)
    }

    public func reject(pendingID: String, by who: String, asAgent: Bool = false) async throws -> PendingAction {
        if asAgent {
            guard let action = try await runtime.pending.get(id: pendingID) else { throw KastellanError.notFound("Pending Action \(pendingID)") }
            guard who == action.client else { throw KastellanError.unauthorized("Pending Action gehört Client \(action.client)") }
        }
        return try await executor.cancel(pendingID: pendingID, by: who)
    }

    /// Parameter ohne Passwörter speichern, damit die Pending-Datei keine Secrets enthält.
    /// Bei der Freigabe wird dann ein neues Passwort erzeugt, wenn keines mehr da ist.
    static func storable(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var out = input
        out.removeValue(forKey: "password")
        return out
    }
}

import Foundation
import KastellanCore
import MCP

/// Baut aus dem Aktionskatalog die MCP-Tools und beantwortet Aufrufe.
/// Sichtbar sind nur Tools, die dieser Client in seinem Profil auf mindestens einer Verbindung nutzen darf.
struct ToolServer {
    let service: ActionService
    let token: ClientToken?
    let profile: KastellanProfile?
    let tokenPresent: Bool

    var runtime: Runtime { service.runtime }

    // MARK: - Tool-Liste

    func tools() async -> [Tool] {
        var tools: [Tool] = [Self.versionTool]
        guard let token, let profile else { return tools }
        tools += Self.overarchingTools
        if let specs = try? await service.visibleSpecs(client: token.client, profile: profile) {
            tools += specs.map(Self.tool(for:))
        }
        return tools
    }

    static let versionTool = Tool(
        name: "kastellan_version",
        description: "Version von Kastellan und Status des Client-Tokens. / Kastellan version and client token status.",
        inputSchema: schema([]),
        annotations: readOnly)

    static let overarchingTools: [Tool] = [
        Tool(name: "kastellan_list_connections",
             description: "Verbindungen zu Hostern in diesem Profil mit Provider, Fähigkeiten und Health. / Hosting connections in this profile with provider, capabilities and health.",
             inputSchema: schema([]), annotations: readOnly),
        Tool(name: "kastellan_get_capabilities",
             description: "Effektive Rechte dieses Clients auf einer Verbindung: pro Ressource die Stufe und was der Provider kann. / Effective permissions of this client on a connection.",
             inputSchema: schema([ActionCatalog.connectionParam]), annotations: readOnly),
        Tool(name: "kastellan_get_policy",
             description: "Policy dieses Clients auf einer Verbindung (Stufen, Domain-Muster, Ausschlüsse, Limits). / Policy of this client on a connection.",
             inputSchema: schema([ActionCatalog.connectionParam]), annotations: readOnly),
        Tool(name: "kastellan_resolve",
             description: "Welche Verbindung ist für eine Domain und eine Ressource zuständig. / Which connection handles a domain and resource type.",
             inputSchema: schema([ParameterSpec("domain", "Domain oder Adresse"), ParameterSpec("resource", required: false, "Ressourcentyp, z. B. mailbox oder dns_record")]),
             annotations: readOnly),
        Tool(name: "kastellan_list_pending",
             description: "Offene Freigaben dieses Clients mit Status und Vorschau. / Pending actions of this client.",
             inputSchema: schema([ParameterSpec("include_final", kind: .boolean, required: false, "Auch abgeschlossene zeigen")]), annotations: readOnly),
        Tool(name: "kastellan_get_pending",
             description: "Eine Freigabe mit Status, Ergebnis und Fehler lesen. / Read one pending action with status, result and error.",
             inputSchema: schema([ParameterSpec("action_id", "Kennung der Pending Action")]), annotations: readOnly),
        Tool(name: "kastellan_confirm_action",
             description: "Freigabe selbst erteilen. Nur erlaubt, wenn die Policy agent_may_confirm setzt; sonst gibt die Kastellan-App frei. / Confirm a pending action (only with agent_may_confirm).",
             inputSchema: schema([ParameterSpec("action_id", "Kennung der Pending Action")]),
             annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true)),
        Tool(name: "kastellan_cancel_action",
             description: "Eigene Pending Action verwerfen. / Cancel one of this client's pending actions.",
             inputSchema: schema([ParameterSpec("action_id", "Kennung der Pending Action")]),
             annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
    ]

    static let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)

    static func tool(for spec: ActionSpec) -> Tool {
        Tool(name: spec.name, description: spec.description, inputSchema: schema(spec.parameters),
             annotations: Tool.Annotations(readOnlyHint: spec.isReadOnly, destructiveHint: spec.isDestructive || spec.prepares,
                                           idempotentHint: spec.isIdempotent, openWorldHint: true))
    }

    static func schema(_ params: [ParameterSpec]) -> Value {
        var props: [String: Value] = [:]
        for p in params {
            var v: [String: Value] = ["description": .string(p.description)]
            switch p.kind {
            case .string: v["type"] = .string("string")
            case .integer: v["type"] = .string("integer")
            case .boolean: v["type"] = .string("boolean")
            case .stringArray: v["type"] = .string("array"); v["items"] = .object(["type": .string("string")])
            case .object: v["type"] = .string("object")
            }
            props[p.name] = .object(v)
        }
        var s: [String: Value] = ["type": .string("object"), "properties": .object(props)]
        let required = params.filter(\.required).map { Value.string($0.name) }
        if !required.isEmpty { s["required"] = .array(required) }
        return .object(s)
    }

    // MARK: - Aufrufe

    func call(_ name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let args = Self.convert(arguments ?? [:])
        let started = Date()
        let isCatalog = ActionCatalog.spec(named: name) != nil
        do {
            let result = try await dispatch(name, args: args)
            // Katalog-Aktionen loggt der Executor selbst, Meta-Tools hier.
            if !isCatalog { audit(name, args: args, outcome: .ok, started: started) }
            return result
        } catch {
            // Fehler vor dem Executor (fehlender Parameter, unbekannte Verbindung) würden sonst fehlen.
            let logged = isCatalog && (error as? KastellanError).map { if case .unauthorized = $0 { true } else if case .unsupported = $0 { true } else { false } } == true
            if !logged { audit(name, args: args, outcome: .error, message: error.localizedDescription, started: started) }
            // Erwartbare Ablehnungen (Rechte, Scope, fehlender Parameter) sind keine Telemetrie-Fälle.
            if let k = error as? KastellanError, case .provider = k {
                await Telemetry.shared.capture(error, tags: ["tool": name])
            } else if let k = error as? KastellanError, case .internal = k {
                await Telemetry.shared.capture(error, tags: ["tool": name])
            } else if !(error is KastellanError) {
                await Telemetry.shared.capture(error, tags: ["tool": name])
            }
            return .init(content: [.text(error.localizedDescription)], isError: true)
        }
    }

    private func audit(_ tool: String, args: [String: JSONValue], outcome: AuditEntry.Outcome, message: String? = nil, started: Date) {
        let input = ActionInput(args)
        let target = input.optionalString("address") ?? input.optionalString("domain") ?? input.optionalString("zone")
            ?? input.optionalString("fqdn") ?? input.optionalString("hostname") ?? input.optionalString("action_id")
        try? runtime.audit.append(AuditEntry(
            client: token?.client ?? "unbekannt", connectionID: input.optionalString("connection_id"), tool: tool,
            capability: ActionCatalog.spec(named: tool)?.capability, target: target, outcome: outcome, message: message,
            durationMS: Int(Date().timeIntervalSince(started) * 1000)))
    }

    private func dispatch(_ name: String, args: [String: JSONValue]) async throws -> CallTool.Result {
        if name == "kastellan_version" { return text(versionText()) }
        guard let token, let profile else {
            throw KastellanError.unauthorized("Kein gültiges Client-Token. Token in der Kastellan-App ausstellen und als KASTELLAN_TOKEN setzen.")
        }
        let input = ActionInput(args)
        switch name {
        case "kastellan_list_connections":
            let health = try runtime.health.latest()
            let list = try await runtime.connections.list(profileID: profile.id)
            var out: [JSONValue] = []
            for c in list {
                let matrix = runtime.registry.capabilityMatrix(for: c.provider)
                out.append(.object([
                    "id": .string(c.id), "provider": .string(c.provider), "label": .string(c.label),
                    "settings": .object(c.settings.mapValues { .string($0) }),
                    "resources": .array((matrix?.resources ?? []).map { .string($0.rawValue) }.sorted { $0.description < $1.description }),
                    "health": health[c.id].map { .object(["ok": .bool($0.ok), "message": .string($0.message), "checked_at": .string($0.checkedAt.formatted(.iso8601))]) } ?? .null,
                ]))
            }
            return json(.array(out))

        case "kastellan_get_capabilities":
            let id = try input.string("connection_id")
            guard let c = try await runtime.connections.get(id: id), c.profileID == profile.id else { throw KastellanError.notFound("Verbindung \(id)") }
            let policy = try await runtime.policies.policy(profile: profile.slug, client: token.client, connectionID: id)
            let matrix = runtime.registry.capabilityMatrix(for: c.provider)
            var rows: [String: JSONValue] = [:]
            for r in ResourceType.allCases {
                let actions = (matrix?.capabilities ?? []).filter { $0.resource == r }.map(\.action)
                guard !actions.isEmpty else { continue }
                let level = policy.level(for: r)
                let allowed = actions.filter { level >= PermissionLevel.required(for: $0) }.map { JSONValue.string($0.rawValue) }
                rows[r.rawValue] = .object([
                    "level": .string(level.rawValue),
                    "provider_actions": .array(actions.map { .string($0.rawValue) }),
                    "allowed_actions": .array(allowed),
                ])
            }
            return json(.object(["connection_id": .string(id), "provider": .string(c.provider), "resources": .object(rows)]))

        case "kastellan_get_policy":
            let id = try input.string("connection_id")
            guard let c = try await runtime.connections.get(id: id), c.profileID == profile.id else { throw KastellanError.notFound("Verbindung \(id)") }
            let policy = try await runtime.policies.policy(profile: profile.slug, client: token.client, connectionID: id)
            return json(try .encode(policy))

        case "kastellan_resolve":
            let domainInput = try input.string("domain")
            let host = domainInput.split(separator: "@").last.map(String.init)?.lowercased() ?? domainInput
            let resource = input.optionalString("resource").flatMap(ResourceType.init(rawValue:))
            var matches: [JSONValue] = []
            // Zuerst die Zuordnung aus der App, dann der Rückfall über die Policy-Domain-Muster.
            for a in try await runtime.assignments.resolve(profileID: profile.id, domain: host, resource: resource) {
                guard let c = try await runtime.connections.get(id: a.connectionID) else { continue }
                matches.append(.object(["connection_id": .string(c.id), "provider": .string(c.provider), "label": .string(c.label),
                                        "source": .string("assignment"), "rule": .string("\(a.domainPattern) \(a.resources.isEmpty ? "*" : a.resources.map(\.rawValue).joined(separator: ","))")]))
            }
            if !matches.isEmpty { return json(.array(matches)) }
            for c in try await runtime.connections.list(profileID: profile.id) {
                let policy = try await runtime.policies.policy(profile: profile.slug, client: token.client, connectionID: c.id)
                let inScope = policy.domainPatterns.isEmpty || PolicyEngine.matches(host, patterns: policy.domainPatterns)
                guard inScope else { continue }
                if let resource {
                    guard runtime.registry.capabilityMatrix(for: c.provider)?.resources.contains(resource) == true,
                          policy.level(for: resource) > .none else { continue }
                }
                matches.append(.object(["connection_id": .string(c.id), "provider": .string(c.provider), "label": .string(c.label),
                                        "source": .string("policy"), "domain_patterns": .array(policy.domainPatterns.map { .string($0) })]))
            }
            return json(.array(matches))

        case "kastellan_list_pending":
            let includeFinal = input.optionalBool("include_final") ?? false
            let mine = try await runtime.pending.list(includeFinal: includeFinal).filter { $0.client == token.client }
            return json(try .encode(mine))

        case "kastellan_get_pending":
            let id = try input.string("action_id")
            guard let a = try await runtime.pending.get(id: id), a.client == token.client else { throw KastellanError.notFound("Pending Action \(id)") }
            return json(try .encode(a))

        case "kastellan_confirm_action":
            let id = try input.string("action_id")
            let done = try await service.approve(pendingID: id, by: token.client, asAgent: true)
            return json(try .encode(done))

        case "kastellan_cancel_action":
            let id = try input.string("action_id")
            return json(try .encode(try await service.reject(pendingID: id, by: token.client, asAgent: true)))

        default:
            guard ActionCatalog.spec(named: name) != nil else { throw KastellanError.notFound("Tool \(name)") }
            let outcome = try await service.call(name, input: args, client: token.client, profile: profile)
            switch outcome {
            case .done(let value):
                return json(value)
            case .pending(let action):
                return json(.object([
                    "status": .string("pending_approval"),
                    "action_id": .string(action.id),
                    "preview": .string(action.preview),
                    "hint": .string("Freigabe in der Kastellan-App nötig. Status mit kastellan_get_pending abfragen. / Needs approval in the Kastellan app; poll with kastellan_get_pending."),
                ]))
            }
        }
    }

    func versionText() -> String {
        let status: String
        if let token, let profile {
            status = "Token für Client \"\(token.client)\" im Profil \"\(profile.name)\" gültig"
        } else if !tokenPresent {
            status = "kein Token (KASTELLAN_TOKEN fehlt), nur kastellan_version verfügbar"
        } else {
            status = "Token ungültig oder widerrufen, nur kastellan_version verfügbar"
        }
        return "Kastellan \(KastellanCore.version), \(status)"
    }

    // MARK: - Hilfen

    private func text(_ s: String) -> CallTool.Result { .init(content: [.text(s)], isError: false) }

    private func json(_ value: JSONValue) -> CallTool.Result {
        let data = (try? JSONCoding.encoder.encode(value)) ?? Data()
        return .init(content: [.text(String(decoding: data, as: UTF8.self))], isError: false)
    }

    /// MCP `Value` → `JSONValue`.
    static func convert(_ values: [String: Value]) -> [String: JSONValue] {
        values.mapValues(convert)
    }

    static func convert(_ v: Value) -> JSONValue {
        switch v {
        case .null: .null
        case .bool(let b): .bool(b)
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        case .string(let s): .string(s)
        case .data(_, let d): .string(d.base64EncodedString())
        case .array(let a): .array(a.map(convert))
        case .object(let o): .object(o.mapValues(convert))
        }
    }
}

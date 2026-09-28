import Foundation
import Testing
@testable import KastellanCore

struct ActionCatalogTests {
    @Test func namesAreUniqueAndFollowConvention() {
        let names = ActionCatalog.all.map(\.name)
        #expect(Set(names).count == names.count)
        for spec in ActionCatalog.all {
            #expect(spec.name.hasPrefix(spec.capability.resource.rawValue + "_"), "\(spec.name)")
            #expect(spec.parameters.first?.name == "connection_id", "\(spec.name)")
            if spec.capability.action == .delete && spec.capability.resource != .mailAutoresponder {
                #expect(spec.prepares, "\(spec.name) sollte prepare_ sein")
                #expect(spec.name.contains("prepare_"), "\(spec.name)")
            }
        }
        #expect(ActionCatalog.all.count >= 58)
        #expect(ActionCatalog.spec(named: "server_update") != nil)
        #expect(ActionCatalog.spec(named: "firewall_list")?.isReadOnly == true)
    }

    @Test func serverPowerActionsRequireConfirmation() throws {
        let spec = try #require(ActionCatalog.spec(named: "server_update"))
        let ctx = ActionContext(connectionID: "c", secrets: InMemorySecretProvider(), revealGeneratedPasswords: false)
        let off = try spec.build(ActionInput(["provider_ref": .string("1"), "power": .string("power_off")]), ctx)
        #expect(off.requiresConfirmation)
        let on = try spec.build(ActionInput(["provider_ref": .string("1"), "power": .string("power_on")]), ctx)
        #expect(!on.requiresConfirmation)
        let rename = try spec.build(ActionInput(["provider_ref": .string("1"), "name": .string("neu")]), ctx)
        #expect(!rename.requiresConfirmation)
        #expect(throws: KastellanError.self) { try spec.build(ActionInput(["provider_ref": .string("1")]), ctx) }
        #expect(throws: KastellanError.self) { try spec.build(ActionInput(["provider_ref": .string("1"), "power": .string("explode")]), ctx) }
        #expect(confirmationRequired.contains(Capability(.server, .create)))
    }

    @Test func eachCapabilityHasOneSpec() {
        let caps = ActionCatalog.all.map(\.capability)
        #expect(Set(caps).count == caps.count)
        #expect(ActionCatalog.spec(for: Capability(.mailbox, .delete))?.name == "mailbox_prepare_delete")
    }

    @Test func serviceCallListsVisibleToolsCallsAndApproves() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var registry = AdapterRegistry()
        registry.register(FakeAdapter.self)
        let secrets = InMemorySecretProvider()
        let runtime = Runtime(
            profiles: ProfileStore(fileURL: dir.appendingPathComponent("profiles.json")),
            connections: ConnectionStore(fileURL: dir.appendingPathComponent("connections.json")),
            assignments: AssignmentStore(fileURL: dir.appendingPathComponent("assignments.json")),
            tokens: TokenStore(fileURL: dir.appendingPathComponent("tokens.json")),
            policies: PolicyStore(directory: dir.appendingPathComponent("policies")),
            pending: PendingActionStore(directory: dir.appendingPathComponent("pending")),
            audit: AuditLog(fileURL: dir.appendingPathComponent("audit.jsonl")),
            health: HealthLog(fileURL: dir.appendingPathComponent("health.jsonl")),
            secrets: secrets, registry: registry,
            credentialSettings: CredentialSettingsStore(fileURL: dir.appendingPathComponent("credentials.json")),
            handoffs: CredentialHandoffStore(directory: dir.appendingPathComponent("handoff"), secrets: secrets))
        let ctx = try #require(try await runtime.profiles.find(slug: "privat"))
        let conn = Connection(profileID: ctx.id, provider: "fake", label: "Fake")
        try await runtime.connections.upsert(conn)
        let service = ActionService(runtime: runtime)

        // Ohne Policy: nichts sichtbar
        #expect(try await service.visibleSpecs(client: "claude-code", profile: ctx).isEmpty)

        try await runtime.policies.set(Policy(levels: [.mailbox: .manage, .dnsRecord: .read], domainPatterns: ["example.com"]),
                                       profile: ctx.slug, client: "claude-code", connectionID: conn.id)
        let visible = try await service.visibleSpecs(client: "claude-code", profile: ctx).map(\.name)
        #expect(visible.contains("mailbox_create"))
        #expect(visible.contains("mailbox_prepare_delete"))
        #expect(visible.contains("dns_record_list"))
        #expect(!visible.contains("dns_record_create"))   // nur read
        #expect(!visible.contains("cron_job_list"))       // Fake kann kein cron

        // Lesen
        let listed = try await service.call("mailbox_list", input: ["connection_id": .string(conn.id), "domain": .string("example.com")], client: "claude-code", profile: ctx)
        guard case .done(let value) = listed, case .array(let boxes) = value else { Issue.record("erwartet Liste"); return }
        #expect(boxes.count == 1)

        // Anlegen ohne Passwort: Ablage „nur im Ergebnis“ liefert das Passwort, speichert nichts
        try await runtime.credentialSettings.set(CredentialDeliveryConfig(kind: .resultOnly), profileID: ctx.id)
        let created = try await service.call("mailbox_create", input: ["connection_id": .string(conn.id), "address": .string("neu@example.com")], client: "claude-code", profile: ctx)
        guard case .done(.object(let obj)) = created else { Issue.record("erwartet done"); return }
        #expect(obj["password"]?.stringValue?.count == 24)
        #expect(obj["password_storage"]?.stringValue?.contains("nicht gespeichert") == true)
        #expect(try await secrets.secret(connectionID: conn.id, key: "mailbox/neu@example.com") == nil)
        // Ablage Bitwarden ohne App: Übergabe, Passwort versteckt
        try await runtime.credentialSettings.set(CredentialDeliveryConfig(kind: .bitwarden, target: CredentialTarget(folderName: "Hosting")), profileID: ctx.id)
        let created2 = try await service.call("mailbox_create", input: ["connection_id": .string(conn.id), "address": .string("neu2@example.com")], client: "claude-code", profile: ctx)
        guard case .done(.object(let obj2)) = created2 else { Issue.record("erwartet done"); return }
        #expect(obj2["password"] == .string("wird abgelegt"))
        #expect(obj2["password_storage"]?.stringValue?.contains("Bitwarden") == true)
        #expect(try await runtime.handoffs.list().count == 1)

        // Löschen: Pending, Freigabe führt aus
        let del = try await service.call("mailbox_prepare_delete", input: ["connection_id": .string(conn.id), "address": .string("neu@example.com"), "password": .string("nie speichern")], client: "claude-code", profile: ctx)
        guard case .pending(let action) = del else { Issue.record("erwartet pending"); return }
        #expect(action.parameters["password"] == nil)
        #expect(action.preview.contains("neu@example.com"))
        let done = try await service.approve(pendingID: action.id, by: "Max")
        #expect(done.status == .done)
        #expect(done.result == .object(["deleted": .string("neu@example.com")]))

        // Agent darf nur mit agent_may_confirm selbst freigeben
        let del2 = try await service.call("mailbox_prepare_delete", input: ["connection_id": .string(conn.id), "address": .string("a@example.com")], client: "claude-code", profile: ctx)
        guard case .pending(let action2) = del2 else { Issue.record("erwartet pending"); return }
        await #expect(throws: KastellanError.self) { _ = try await service.approve(pendingID: action2.id, by: "claude-code", asAgent: true) }
        await #expect(throws: KastellanError.self) { _ = try await service.approve(pendingID: action2.id, by: "anderer-client", asAgent: true) }
        try await runtime.policies.set(Policy(levels: [.mailbox: .manage], domainPatterns: ["example.com"], agentMayConfirm: true),
                                       profile: ctx.slug, client: "claude-code", connectionID: conn.id)
        #expect(try await service.approve(pendingID: action2.id, by: "claude-code", asAgent: true).status == .done)

        // Ohne connection_id: eindeutige Verbindung über Policy-Rückfall, dann über Zuordnung
        let auto = try await service.call("mailbox_list", input: ["domain": .string("example.com")], client: "claude-code", profile: ctx)
        guard case .done = auto else { Issue.record("erwartet done ohne connection_id"); return }
        let second = Connection(profileID: ctx.id, provider: "fake", label: "Fake 2")
        try await runtime.connections.upsert(second)
        try await runtime.policies.set(Policy(levels: [.mailbox: .read], domainPatterns: ["*"]), profile: ctx.slug, client: "claude-code", connectionID: second.id)
        await #expect(throws: KastellanError.self) {
            _ = try await service.call("mailbox_list", input: ["domain": .string("example.com")], client: "claude-code", profile: ctx)
        }
        try await runtime.assignments.upsert(Assignment(profileID: ctx.id, domainPattern: "example.com", resource: .mailbox, connectionID: second.id))
        // Eine Regel für alles darf die genauere nicht mehrdeutig machen
        try await runtime.assignments.upsert(Assignment(profileID: ctx.id, domainPattern: "*", resources: [], connectionID: conn.id))
        let viaAssignment = try await service.call("mailbox_list", input: ["domain": .string("example.com")], client: "claude-code", profile: ctx)
        guard case .done = viaAssignment else { Issue.record("erwartet done über Zuordnung"); return }
        #expect(try runtime.audit.entries().last?.connectionID == second.id)
        try await runtime.connections.delete(id: second.id)

        // Außerhalb des Scopes
        await #expect(throws: KastellanError.self) {
            _ = try await service.call("mailbox_get", input: ["connection_id": .string(conn.id), "address": .string("x@fremd.de")], client: "claude-code", profile: ctx)
        }
        // Fehlender Parameter
        await #expect(throws: KastellanError.self) {
            _ = try await service.call("mailbox_get", input: ["connection_id": .string(conn.id)], client: "claude-code", profile: ctx)
        }
    }

    @Test func inputHelpers() {
        let input = ActionInput(["a": .string("1,2 , 3"), "b": .array([.string("x"), .int(2)]), "c": .string("yes"), "d": .int(5), "e": .string("")])
        #expect(input.stringArray("a") == ["1", "2", "3"])
        #expect(input.stringArray("b") == ["x", "2"])
        #expect(input.optionalBool("c") == true)
        #expect(input.optionalInt("d") == 5)
        #expect(input.optionalString("e") == nil)
        #expect(PasswordGenerator.generate().count == 24)
    }
}

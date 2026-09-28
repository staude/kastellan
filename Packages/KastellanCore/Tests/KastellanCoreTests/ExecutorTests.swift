import Foundation
import Testing
@testable import KastellanCore

struct ExecutorTests {
    struct Env {
        let runtime: Runtime
        let executor: ActionExecutor
        let profile: KastellanProfile
        let connection: Connection
        let dir: URL
    }

    func makeEnv(policy: Policy) async throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var registry = AdapterRegistry()
        registry.register(FakeAdapter.self)
        let runtime = Runtime(
            profiles: ProfileStore(fileURL: dir.appendingPathComponent("profiles.json")),
            connections: ConnectionStore(fileURL: dir.appendingPathComponent("connections.json")),
            assignments: AssignmentStore(fileURL: dir.appendingPathComponent("assignments.json")),
            tokens: TokenStore(fileURL: dir.appendingPathComponent("tokens.json")),
            policies: PolicyStore(directory: dir.appendingPathComponent("policies")),
            pending: PendingActionStore(directory: dir.appendingPathComponent("pending")),
            audit: AuditLog(fileURL: dir.appendingPathComponent("audit.jsonl")),
            health: HealthLog(fileURL: dir.appendingPathComponent("health.jsonl")),
            secrets: InMemorySecretProvider(), registry: registry,
            credentialSettings: CredentialSettingsStore(fileURL: dir.appendingPathComponent("credentials.json")),
            handoffs: CredentialHandoffStore(directory: dir.appendingPathComponent("handoff"), secrets: InMemorySecretProvider()))
        let ctx = try #require(try await runtime.profiles.find(slug: "privat"))
        let conn = Connection(profileID: ctx.id, provider: "fake", label: "Fake")
        try await runtime.connections.upsert(conn)
        try await runtime.policies.set(policy, profile: ctx.slug, client: "claude-code", connectionID: conn.id)
        return Env(runtime: runtime, executor: ActionExecutor(runtime: runtime), profile: ctx, connection: conn, dir: dir)
    }

    func request(_ env: Env, _ cap: Capability, target: String? = "x@example.com") -> ActionRequest {
        ActionRequest(client: "claude-code", profile: env.profile, connectionID: env.connection.id, capability: cap, target: target, preview: "Test")
    }

    @Test func allowedRunsAdapterAndLogs() async throws {
        let env = try await makeEnv(policy: Policy(levels: [.mailbox: .write], domainPatterns: ["example.com"]))
        let outcome = try await env.executor.perform(request(env, Capability(.mailbox, .list))) { adapter in
            let boxes = try await (adapter as! any MailboxAdapter).listMailboxes(domain: "example.com")
            return .array(boxes.map { .string($0.address) })
        }
        guard case .done(let value) = outcome else { Issue.record("erwartet done"); return }
        #expect(value == .array([.string("a@example.com")]))
        let entries = try env.runtime.audit.entries()
        #expect(entries.count == 1)
        #expect(entries[0].outcome == .ok)
        #expect(entries[0].durationMS != nil)
    }

    @Test func deniedOutOfScopeUnsupported() async throws {
        let env = try await makeEnv(policy: Policy(levels: [.mailbox: .read], domainPatterns: ["example.com"]))
        await #expect(throws: KastellanError.self) {
            _ = try await env.executor.perform(request(env, Capability(.mailbox, .create))) { _ in .null }
        }
        await #expect(throws: KastellanError.self) {
            _ = try await env.executor.perform(request(env, Capability(.mailbox, .list), target: "x@fremd.de")) { _ in .null }
        }
        await #expect(throws: KastellanError.self) {
            _ = try await env.executor.perform(request(env, Capability(.cronJob, .list))) { _ in .null }
        }
        let outcomes = try env.runtime.audit.entries().map(\.outcome)
        #expect(outcomes == [.denied, .outOfScope, .unsupported])
    }

    @Test func confirmationFlow() async throws {
        let env = try await makeEnv(policy: Policy(levels: [.mailbox: .manage], domainPatterns: ["example.com"]))
        let outcome = try await env.executor.perform(request(env, Capability(.mailbox, .delete))) { _ in .null }
        guard case .pending(let action) = outcome else { Issue.record("erwartet pending"); return }
        #expect(action.status == .prepared)
        #expect(try await env.runtime.pending.list().count == 1)

        let done = try await env.executor.execute(pendingID: action.id, by: "Max") { adapter in
            try await (adapter as! any MailboxAdapter).deleteMailbox(address: "x@example.com")
            return .object(["deleted": .bool(true)])
        }
        #expect(done.status == .done)
        #expect(done.result == .object(["deleted": .bool(true)]))
        let outcomes = try env.runtime.audit.entries().map(\.outcome)
        #expect(outcomes == [.pending, .confirmed])
        await #expect(throws: KastellanError.self) {
            _ = try await env.executor.execute(pendingID: action.id, by: "Max") { _ in .null }
        }
    }

    @Test func cancelAndFailure() async throws {
        let env = try await makeEnv(policy: Policy(levels: [.mailbox: .manage], domainPatterns: ["example.com"]))
        let first = try await env.executor.perform(request(env, Capability(.mailbox, .delete)), operation: { _ in .null })
        guard case .pending(let a) = first else { Issue.record("erwartet pending"); return }
        #expect(try await env.executor.cancel(pendingID: a.id, by: "Max").status == .cancelled)

        let second = try await env.executor.perform(request(env, Capability(.mailbox, .delete)), operation: { _ in .null })
        guard case .pending(let b) = second else { Issue.record("erwartet pending"); return }
        let failed = try await env.executor.execute(pendingID: b.id, by: "Max") { _ in throw KastellanError.provider("kaputt") }
        #expect(failed.status == .failed)
        #expect(failed.error?.contains("kaputt") == true)
    }

    @Test func writeLimit() async throws {
        let env = try await makeEnv(policy: Policy(levels: [.mailbox: .write], domainPatterns: ["example.com"], maxWritesPerHour: 2))
        for _ in 0..<2 {
            _ = try await env.executor.perform(request(env, Capability(.mailbox, .create))) { _ in .null }
        }
        await #expect(throws: KastellanError.self) {
            _ = try await env.executor.perform(request(env, Capability(.mailbox, .create))) { _ in .null }
        }
        // Lesen bleibt erlaubt
        _ = try await env.executor.perform(request(env, Capability(.mailbox, .list))) { _ in .null }
    }

    @Test func foreignProfileIsOutOfScope() async throws {
        let env = try await makeEnv(policy: Policy(levels: [.mailbox: .write], domainPatterns: ["example.com"]))
        let other = try #require(try await env.runtime.profiles.find(slug: "beruflich"))
        var req = request(env, Capability(.mailbox, .list))
        req.profile = other
        #expect(try await env.executor.authorize(req) == .outOfScope)
    }
}

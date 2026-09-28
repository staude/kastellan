import Foundation
import Testing
@testable import KastellanCore

/// Fake-Adapter, der nur Postfächer und DNS kann. Zeigt das Muster für echte Adapter.
struct FakeAdapter: MailboxAdapter, DNSAdapter {
    static let providerID = "fake"
    static let displayName = "Fake-Hoster"
    static let capabilityMatrix = CapabilityMatrix(provider: providerID, capabilities:
        CapabilityMatrix.full(.mailbox) .union(CapabilityMatrix.only(.dnsRecord, .list, .create, .delete)))
    static let settingKeys = [SettingKey("login", label: "Login")]
    static let secretKeys = [SettingKey("password", label: "Passwort")]

    let connection: Connection
    let secrets: any SecretProvider

    init(connection: Connection, secrets: any SecretProvider) {
        self.connection = connection
        self.secrets = secrets
    }

    func healthCheck() async -> HealthStatus {
        let ok = (try? await secrets.secret(connectionID: connection.id, key: "password")) != nil
        return HealthStatus(connectionID: connection.id, ok: ok, message: ok ? "ok" : "kein Passwort")
    }

    var ref: ResourceRef { ResourceRef(connectionID: connection.id, providerRef: "x") }

    func listMailboxes(domain: String?) async throws -> [Mailbox] { [Mailbox(ref: ref, address: "a@\(domain ?? "d.de")")] }
    func getMailbox(address: String) async throws -> Mailbox? { nil }
    func createMailbox(_ spec: MailboxSpec) async throws -> Mailbox { Mailbox(ref: ref, address: spec.address) }
    func updateMailbox(_ spec: MailboxSpec) async throws -> Mailbox { Mailbox(ref: ref, address: spec.address) }
    func setMailboxPassword(address: String, password: String) async throws {}
    func deleteMailbox(address: String) async throws {}

    func listZones() async throws -> [DNSZone] { [] }
    func listRecords(zone: String) async throws -> [DNSRecord] { [] }
    func createRecord(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        DNSRecord(ref: ref, zone: zone, name: name, type: type, content: content, ttl: ttl, priority: priority)
    }
    func updateRecord(zone: String, providerRef: String, content: String?, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        DNSRecord(ref: ref, zone: zone, name: "@", type: "A", content: content ?? "")
    }
    func deleteRecord(zone: String, providerRef: String) async throws {}
}

struct AdapterRegistryTests {
    @Test func registryBuildsAdapterAndExposesMatrix() async throws {
        var registry = AdapterRegistry()
        registry.register(FakeAdapter.self)
        let conn = Connection(profileID: "ctx", provider: "fake", label: "Test", settings: ["login": "u"])
        let secrets = InMemorySecretProvider()
        await secrets.set(connectionID: conn.id, key: "password", value: "geheim")

        let adapter = try registry.adapter(for: conn, secrets: secrets)
        #expect(adapter.healthCheck != nil)
        let health = await adapter.healthCheck()
        #expect(health.ok)
        #expect(registry.capabilityMatrix(for: "fake")?.supports(Capability(.mailbox, .delete)) == true)
        #expect(registry.capabilityMatrix(for: "fake")?.supports(Capability(.dnsRecord, .update)) == false)
        #expect(registry.capabilityMatrix(for: "fake")?.resources == [.mailbox, .dnsRecord])
        #expect(throws: KastellanError.self) {
            try registry.adapter(for: Connection(profileID: "ctx", provider: "nope", label: ""), secrets: secrets)
        }
    }

    @Test func protocolCastingSelectsCapability() async throws {
        let adapter: any ProviderAdapter = FakeAdapter(connection: Connection(profileID: "ctx", provider: "fake", label: ""), secrets: InMemorySecretProvider())
        #expect(adapter as? any MailboxAdapter != nil)
        #expect(adapter as? any CronJobAdapter == nil)
        let mailboxes = try await (adapter as! any MailboxAdapter).listMailboxes(domain: "example.com")
        #expect(mailboxes.first?.address == "a@example.com")
    }

    @Test func defaultApplyChangesRunsSequentially() async throws {
        let adapter = FakeAdapter(connection: Connection(profileID: "ctx", provider: "fake", label: ""), secrets: InMemorySecretProvider())
        let touched = try await adapter.applyChanges(zone: "example.com", changes: [
            .create(name: "www", type: "A", content: "1.2.3.4", ttl: nil, priority: nil),
            .delete(providerRef: "1"),
            .update(providerRef: "2", content: "5.6.7.8", ttl: nil, priority: nil),
        ])
        #expect(touched.count == 2)
        #expect(touched.first?.name == "www")
    }
}

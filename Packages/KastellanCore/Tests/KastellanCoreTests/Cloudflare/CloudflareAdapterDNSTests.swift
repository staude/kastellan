import Foundation
import Testing
@testable import KastellanCore

struct CloudflareAdapterDNSTests {
    let zoneID = CloudflareFixtures.zoneID

    @Test func adapterMetadata() {
        #expect(CloudflareAdapter.providerID == "cloudflare")
        #expect(CloudflareAdapter.displayName == "Cloudflare")
        #expect(CloudflareAdapter.settingKeys.map(\.key) == ["account_id"])
        #expect(CloudflareAdapter.secretKeys.map(\.key) == ["api_token"])
        let m = CloudflareAdapter.capabilityMatrix
        #expect(m.supports(Capability(.dnsZone, .list)))
        #expect(!m.supports(Capability(.dnsZone, .create)))
        #expect(m.supports(Capability(.dnsRecord, .list)))
        #expect(m.supports(Capability(.dnsRecord, .create)))
        #expect(m.supports(Capability(.dnsRecord, .update)))
        #expect(m.supports(Capability(.dnsRecord, .delete)))
        #expect(!m.supports(Capability(.dnsRecord, .get)))
        #expect(!m.supports(Capability(.mailbox, .list)))
        #expect(!m.supports(Capability(.domain, .list)))
    }

    @Test func builtinRegistryKnowsCloudflare() throws {
        let entry = try #require(BuiltinAdapters.registry.entry(for: "cloudflare"))
        #expect(entry.displayName == "Cloudflare")
        #expect(entry.capabilityMatrix.supports(Capability(.dnsRecord, .list)))
        let conn = Connection(profileID: "privat", provider: "cloudflare", label: "CF")
        let adapter = try BuiltinAdapters.registry.adapter(for: conn, secrets: InMemorySecretProvider())
        #expect(adapter is CloudflareAdapter)
        #expect(adapter as? any DNSAdapter != nil)
        #expect(adapter as? any MailboxAdapter == nil)
    }

    // MARK: - Health

    @Test func healthCheckIsOkForActiveToken() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([try CloudflareFixtures.response("tokens-verify")])
        let health = await adapter.healthCheck()
        #expect(health.ok)
        #expect(health.connectionID == "conn-cf")
        #expect(health.message == "Cloudflare Nutzer-Token aktiv, gültig bis 2027-01-01T00:00:00Z")
        #expect(await transport.calls == ["GET /user/tokens/verify"])
    }

    @Test func healthCheckFailsForExpiredToken() async throws {
        let (adapter, _) = CloudflareFixtures.adapter([try CloudflareFixtures.response("tokens-verify-expired")])
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message.hasPrefix("Cloudflare Nutzer-Token expired"))
    }

    @Test func healthCheckReportsProviderError() async throws {
        let (adapter, _) = CloudflareFixtures.adapter([try CloudflareFixtures.response("error-authentication", status: 403)])
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message.contains("10000: Authentication error"))
    }

    @Test func missingTokenIsUnauthorized() async throws {
        let conn = Connection(id: "c-leer", profileID: "privat", provider: "cloudflare", label: "")
        let adapter = CloudflareAdapter(connection: conn, secrets: InMemorySecretProvider())
        await #expect(throws: KastellanError.unauthorized("Kein Cloudflare-API-Token im Schlüsselbund für Verbindung c-leer")) {
            try await adapter.listZones()
        }
    }

    // MARK: - Namen

    @Test func relativeAndAbsoluteNames() {
        #expect(CloudflareAdapter.relativeName("example.com", zone: "example.com") == "@")
        #expect(CloudflareAdapter.relativeName("www.example.com", zone: "example.com") == "www")
        #expect(CloudflareAdapter.relativeName("a.b.example.com", zone: "Example.com.") == "a.b")
        #expect(CloudflareAdapter.relativeName("fremd.de", zone: "example.com") == "fremd.de")
        #expect(CloudflareAdapter.absoluteName("@", zone: "example.com") == "example.com")
        #expect(CloudflareAdapter.absoluteName("", zone: "example.com") == "example.com")
        #expect(CloudflareAdapter.absoluteName("www", zone: "example.com") == "www.example.com")
        #expect(CloudflareAdapter.absoluteName("www.example.com", zone: "example.com") == "www.example.com")
        #expect(CloudflareAdapter.absoluteName("example.com", zone: "example.com") == "example.com")
    }

    // MARK: - Zonen

    @Test func listZonesMapsFixtureAndPrimesCache() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-list"),
            try CloudflareFixtures.response("dns_records-list"),
        ])
        let zones = try await adapter.listZones()
        #expect(zones.map(\.zone) == ["example.com", "beispiel-zone.de"])
        let first = try #require(zones.first)
        #expect(first.ref == ResourceRef(connectionID: "conn-cf", providerRef: zoneID))
        #expect(first.extra["id"] == .string(zoneID))
        #expect(first.extra["status"] == .string("active"))
        #expect(first.extra["plan"] == .string("Free Website"))
        #expect(first.extra["name_servers"] == .array([.string("ada.ns.cloudflare.com"), .string("rob.ns.cloudflare.com")]))
        #expect(zones[1].extra["status"] == .string("pending"))
        #expect(zones[1].extra["plan"] == .string("Pro Website"))

        // Der Cache kennt die Zone, `listRecords` braucht kein `GET /zones?name=` mehr.
        _ = try await adapter.listRecords(zone: "example.com")
        #expect(await transport.calls == ["GET /zones", "GET /zones/\(zoneID)/dns_records"])
    }

    // MARK: - Records

    @Test func listRecordsLooksUpZoneAndMapsNamesTTLAndExtra() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("dns_records-list"),
        ])
        let records = try await adapter.listRecords(zone: "example.com")
        #expect(await transport.calls == ["GET /zones", "GET /zones/\(zoneID)/dns_records"])
        #expect(await transport.requests[0].query["name"] == "example.com")
        #expect(records.count == 4)

        let apex = records[0]
        #expect(apex.ref.providerRef == "372e67954025e0ba6aaa6d586b9e0b59")
        #expect(apex.zone == "example.com")
        #expect(apex.name == "@")
        #expect(apex.type == "A")
        #expect(apex.content == "198.51.100.4")
        #expect(apex.ttl == nil)
        #expect(apex.priority == nil)
        #expect(apex.extra["proxied"] == .bool(true))
        #expect(apex.extra["comment"] == nil)
        #expect(apex.extra["id"] == .string("372e67954025e0ba6aaa6d586b9e0b59"))

        let www = records[1]
        #expect(www.name == "www")
        #expect(www.type == "CNAME")
        #expect(www.extra["comment"] == .string("Weiterleitung auf den Apex"))

        let mx = records[2]
        #expect(mx.name == "@")
        #expect(mx.type == "MX")
        #expect(mx.priority == 10)
        #expect(mx.ttl == 3600)
        #expect(mx.isProtected)
        #expect(mx.extra["proxied"] == .bool(false))

        let dmarc = records[3]
        #expect(dmarc.name == "_dmarc")
        #expect(dmarc.ttl == 300)
        #expect(dmarc.content == "\"v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com\"")
    }

    @Test func unknownZoneIsNotFound() async throws {
        let (adapter, _) = CloudflareFixtures.adapter([try CloudflareFixtures.response("zones-empty")])
        await #expect(throws: KastellanError.notFound("Zone nix.de bei Cloudflare")) {
            try await adapter.listRecords(zone: "nix.de")
        }
    }

    @Test func createRecordSendsAbsoluteNameAndAutoTTL() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("dns_record-create"),
        ])
        let record = try await adapter.createRecord(zone: "example.com", name: "planer", type: "a", content: "203.0.113.10", ttl: nil, priority: nil)
        #expect(record.name == "planer")
        #expect(record.type == "A")
        #expect(record.ttl == nil)
        #expect(record.ref.providerRef == "b7c8d9e0f1a2b3c4d5e6f708192a3b4c")
        #expect(record.extra["proxied"] == .bool(false))

        let request = try #require(await transport.requests.last)
        #expect(request.method == "POST")
        #expect(request.path == "/zones/\(zoneID)/dns_records")
        #expect(request.object == ["name": .string("planer.example.com"), "type": .string("A"), "content": .string("203.0.113.10"), "ttl": .int(1)])
    }

    @Test func createRecordAtApexWithPriorityAndTTL() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("dns_record-create"),
        ])
        _ = try await adapter.createRecord(zone: "example.com", name: "@", type: "MX", content: "mail.example.com", ttl: 3600, priority: 20)
        let body = try #require(await transport.requests.last?.object)
        #expect(body["name"] == .string("example.com"))
        #expect(body["type"] == .string("MX"))
        #expect(body["ttl"] == .int(3600))
        #expect(body["priority"] == .int(20))
    }

    @Test func updateRecordPatchesOnlyGivenFields() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("dns_record-patch"),
        ])
        let record = try await adapter.updateRecord(zone: "example.com", providerRef: "4c7b3d2e1f0a9b8c7d6e5f4a3b2c1d0e", content: "neu.example.com", ttl: nil, priority: nil)
        #expect(record.content == "neu.example.com")
        #expect(record.name == "www")
        let request = try #require(await transport.requests.last)
        #expect(request.method == "PATCH")
        #expect(request.path == "/zones/\(zoneID)/dns_records/4c7b3d2e1f0a9b8c7d6e5f4a3b2c1d0e")
        #expect(request.object == ["content": .string("neu.example.com")])
    }

    @Test func deleteRecordUsesRecordID() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("dns_record-delete"),
        ])
        try await adapter.deleteRecord(zone: "example.com", providerRef: "1a2b3c4d5e6f708192a3b4c5d6e7f809")
        let request = try #require(await transport.requests.last)
        #expect(request.method == "DELETE")
        #expect(request.path == "/zones/\(zoneID)/dns_records/1a2b3c4d5e6f708192a3b4c5d6e7f809")
        #expect(request.body == nil)
    }

    @Test func deleteMissingRecordIsProviderError() async throws {
        let (adapter, _) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("error-record_not_found", status: 404),
        ])
        await #expect(throws: KastellanError.provider("81044: Record does not exist.; 1004: DNS Validation Error")) {
            try await adapter.deleteRecord(zone: "example.com", providerRef: "gibt-es-nicht")
        }
    }

    // MARK: - Batch

    @Test func applyChangesUsesBatchEndpoint() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("dns_records-batch"),
        ])
        let touched = try await adapter.applyChanges(zone: "example.com", changes: [
            .delete(providerRef: "1a2b3c4d5e6f708192a3b4c5d6e7f809"),
            .update(providerRef: "4c7b3d2e1f0a9b8c7d6e5f4a3b2c1d0e", content: "neu.example.com", ttl: nil, priority: nil),
            .create(name: "api", type: "A", content: "203.0.113.20", ttl: nil, priority: nil),
        ])
        let request = try #require(await transport.requests.last)
        #expect(request.method == "POST")
        #expect(request.path == "/zones/\(zoneID)/dns_records/batch")
        #expect(request.object == [
            "deletes": .array([.object(["id": .string("1a2b3c4d5e6f708192a3b4c5d6e7f809")])]),
            "patches": .array([.object(["id": .string("4c7b3d2e1f0a9b8c7d6e5f4a3b2c1d0e"), "content": .string("neu.example.com")])]),
            "posts": .array([.object(["name": .string("api.example.com"), "type": .string("A"), "content": .string("203.0.113.20"), "ttl": .int(1)])]),
        ])
        // Zurück kommen Angelegtes und Geändertes, Gelöschtes nicht.
        #expect(touched.map(\.name) == ["api", "www"])
        #expect(touched[0].ref.providerRef == "c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e")
        #expect(touched[1].content == "neu.example.com")
    }

    @Test func applyChangesWithoutChangesMakesNoCall() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([])
        let touched = try await adapter.applyChanges(zone: "example.com", changes: [])
        #expect(touched.isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test func batchBodyOmitsEmptyLists() {
        let body = CloudflareAdapter.batchBody(zone: "example.com", changes: [.delete(providerRef: "x")])
        #expect(body.objectValue?.keys.sorted() == ["deletes"])
    }
}

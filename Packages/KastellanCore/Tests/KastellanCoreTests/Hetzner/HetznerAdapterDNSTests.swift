import Foundation
import Testing
@testable import KastellanCore

struct HetznerAdapterDNSTests {
    @Test func adapterMetadata() {
        #expect(HetznerAdapter.providerID == "hetzner")
        #expect(HetznerAdapter.displayName == "Hetzner Cloud")
        #expect(HetznerAdapter.settingKeys.map(\.key) == ["project"])
        #expect(HetznerAdapter.secretKeys.map(\.key) == ["api_token"])
        let m = HetznerAdapter.capabilityMatrix
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

    @Test func registryBuildsAdapterFromConnection() throws {
        var registry = AdapterRegistry()
        registry.register(HetznerAdapter.self)
        let adapter = try registry.adapter(for: HetznerFixtures.connection(), secrets: InMemorySecretProvider())
        #expect(adapter is HetznerAdapter)
        #expect(adapter as? any DNSAdapter != nil)
        #expect(adapter as? any MailboxAdapter == nil)
    }

    @Test func builtinRegistryKnowsHetzner() {
        let entry = BuiltinAdapters.registry.entry(for: "hetzner")
        #expect(entry?.displayName == "Hetzner Cloud")
        #expect(entry?.capabilityMatrix.supports(Capability(.dnsRecord, .create)) == true)
        #expect(BuiltinAdapters.registry.entry(for: "allinkl") != nil)
    }

    @Test func missingTokenIsUnauthorized() async throws {
        let adapter = HetznerAdapter(connection: HetznerFixtures.connection(id: "c-leer"), secrets: InMemorySecretProvider())
        await #expect(throws: KastellanError.unauthorized("Kein Hetzner-API-Token im Schlüsselbund für Verbindung c-leer")) {
            try await adapter.listZones()
        }
    }

    // MARK: - Health

    @Test func healthCheckCountsSSHKeys() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("ssh_keys")])
        let health = await adapter.healthCheck()
        #expect(health.ok)
        #expect(health.connectionID == "conn-hetzner")
        #expect(health.message == "Projekt Test: ok, 2 SSH-Keys, Rate-Limit 3599 übrig")
        let req = try #require(await transport.requests.first)
        #expect(req.path == "/ssh_keys")
        #expect(req.query == ["per_page": "1"])
    }

    @Test func healthCheckReportsRejectedToken() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("error-unauthorized", status: 401)])
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message == "API-Token abgelehnt (unauthorized: unable to authenticate)")
    }

    @Test func healthCheckReportsOtherErrors() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([HetznerFixtures.error(503, code: "maintenance", message: "Cannot perform operation due to maintenance")])
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message.contains("maintenance: Cannot perform operation due to maintenance"))
    }

    // MARK: - Zonen

    @Test func listZonesMapsFixture() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("zones")])
        let zones = try await adapter.listZones()
        #expect(zones.map(\.zone) == ["example.com", "example.com"])
        #expect(zones.map(\.ref.providerRef) == ["42", "43"])
        #expect(zones[0].ref.connectionID == "conn-hetzner")
        #expect(zones[0].defaultTTL == 10800)
        #expect(zones[0].extra["mode"] == .string("primary"))
        #expect(zones[0].extra["status"] == .string("ok"))
        #expect(zones[0].extra["record_count"] == .int(7))
        #expect(zones[0].extra["nameservers"] == .array([.string("hydrogen.ns.hetzner.com."), .string("oxygen.ns.hetzner.com."), .string("helium.ns.hetzner.de.")]))
        #expect(zones[0].extra["delegation_status"] == .string("valid"))
        #expect(zones[0].extra["primary_nameservers"] == .array([]))
        #expect(zones[1].extra["mode"] == .string("secondary"))
        #expect(zones[1].extra["primary_nameservers"] == .array([.string("198.51.100.1"), .string("203.0.113.1")]))
        #expect(zones[1].extra["protection"] == .object(["delete": .bool(true)]))
        let req = try #require(await transport.requests.first)
        #expect(req.path == "/zones")
        #expect(req.query == ["page": "1", "per_page": "50"])
    }

    // MARK: - Records

    @Test func listRecordsExpandsRRSets() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("rrsets")])
        let records = try await adapter.listRecords(zone: "Example.com")
        #expect(await transport.requests.first?.path == "/zones/example.com/rrsets")
        #expect(records.count == 8)
        #expect(records.map(\.ref.providerRef) == [
            "@/A/0", "www/A/0", "www/A/1", "@/MX/0", "@/NS/0", "@/NS/1", "@/NS/2", "_dmarc/TXT/0",
        ])
        // Werte eines RRSets sind nach Wert sortiert, damit der Index stabil bleibt.
        #expect(records[1].content == "198.51.100.1")
        #expect(records[2].content == "198.51.100.2")
        #expect(records[1].ttl == nil)
        #expect(records[1].extra["labels"] == .object(["managed-by": .string("kastellan")]))
        #expect(records[1].extra["rrset_id"] == .string("www/A"))

        let apex = records[0]
        #expect(apex.zone == "Example.com")
        #expect(apex.name == "@")
        #expect(apex.type == "A")
        #expect(apex.ttl == 3600)
        #expect(apex.extra["comment"] == .string("Webserver"))
        #expect(apex.ref.connectionID == "conn-hetzner")

        let mx = records[3]
        #expect(mx.type == "MX")
        #expect(mx.content == "10 mail.example.com.")
        #expect(mx.priority == nil)
        #expect(mx.isProtected)
        #expect(mx.extra["protected"] == .bool(true))
        #expect(records[4].extra["protected"] == nil)
        #expect(records[7].content == "\"v=DMARC1; p=none; rua=mailto:dmarc@example.com\"")
    }

    @Test func createRecordCreatesNewRRSet() async throws {
        let (adapter, transport, sleeps) = HetznerFixtures.adapter([
            HetznerFixtures.notFound("rrset"),
            try HetznerFixtures.ok("rrset-create"),
            try HetznerFixtures.ok("action-success"),
            try HetznerFixtures.ok("rrset-create"),
        ])
        let record = try await adapter.createRecord(zone: "example.com", name: "api.example.com", type: "a", content: "203.0.113.10", ttl: 600, priority: nil)
        #expect(record.ref.providerRef == "api/A/0")
        #expect(record.name == "api")
        #expect(record.type == "A")
        #expect(record.content == "203.0.113.10")
        #expect(record.ttl == 600)

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "POST", "GET", "GET"])
        #expect(requests[0].path == "/zones/example.com/rrsets/api/A")
        #expect(requests[1].path == "/zones/example.com/rrsets")
        #expect(requests[1].body == .object([
            "name": .string("api"), "type": .string("A"), "ttl": .int(600),
            "records": .array([.object(["value": .string("203.0.113.10")])]),
        ]))
        #expect(requests[2].path == "/actions/1001")
        #expect(requests[3].path == "/zones/example.com/rrsets/api/A")
        #expect(await sleeps.seconds == [1])
    }

    @Test func createRecordAddsToExistingRRSet() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            try HetznerFixtures.ok("rrset-www-a"),
            HetznerFixtures.action(command: "add_rrset_records"),
            HetznerFixtures.json(#"{"rrset":{"id":"www/A","name":"www","type":"A","ttl":300,"labels":{},"protection":{"change":false},"records":[{"value":"198.51.100.2"},{"value":"198.51.100.1"},{"value":"198.51.100.3"}],"zone":42}}"#),
        ])
        let record = try await adapter.createRecord(zone: "example.com", name: "www", type: "A", content: "198.51.100.3", ttl: nil, priority: nil)
        #expect(record.ref.providerRef == "www/A/2")
        #expect(record.ttl == 300)
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(requests[1].path == "/zones/example.com/rrsets/www/A/actions/add_records")
        #expect(requests[1].body == .object(["records": .array([.object(["value": .string("198.51.100.3")])])]))
    }

    @Test func createRecordChangesTTLWhenAddingWithDifferentTTL() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            try HetznerFixtures.ok("rrset-www-a"),
            HetznerFixtures.action(command: "add_rrset_records"),
            HetznerFixtures.action(command: "change_rrset_ttl"),
            HetznerFixtures.json(#"{"rrset":{"id":"www/A","name":"www","type":"A","ttl":120,"labels":{},"protection":{"change":false},"records":[{"value":"198.51.100.1"},{"value":"198.51.100.2"},{"value":"198.51.100.3"}],"zone":42}}"#),
        ])
        let record = try await adapter.createRecord(zone: "example.com", name: "www", type: "A", content: "198.51.100.3", ttl: 120, priority: nil)
        #expect(record.ttl == 120)
        let requests = await transport.requests
        #expect(requests[2].path == "/zones/example.com/rrsets/www/A/actions/change_ttl")
        #expect(requests[2].body == .object(["ttl": .int(120)]))
    }

    @Test func createRecordCombinesPriorityForMX() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            HetznerFixtures.notFound("rrset"),
            HetznerFixtures.action(command: "create_rrset"),
            HetznerFixtures.json(#"{"rrset":{"id":"@/MX","name":"@","type":"MX","ttl":null,"labels":{},"protection":{"change":false},"records":[{"value":"10 mail.example.com."}],"zone":42}}"#),
        ])
        let record = try await adapter.createRecord(zone: "example.com", name: "", type: "MX", content: "mail.example.com.", ttl: nil, priority: 10)
        #expect(record.ref.providerRef == "@/MX/0")
        #expect(record.content == "10 mail.example.com.")
        let requests = await transport.requests
        #expect(requests[0].path == "/zones/example.com/rrsets/@/MX")
        #expect(requests[1].body == .object([
            "name": .string("@"), "type": .string("MX"),
            "records": .array([.object(["value": .string("10 mail.example.com.")])]),
        ]))
    }

    @Test func createRecordRejectsDuplicateValue() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("rrset-www-a")])
        await #expect(throws: KastellanError.invalidArgument("Record www A mit Wert 198.51.100.1 existiert bereits in example.com")) {
            try await adapter.createRecord(zone: "example.com", name: "www", type: "A", content: "198.51.100.1", ttl: nil, priority: nil)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func updateRecordReplacesIndexedValue() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            try HetznerFixtures.ok("rrset-www-a"),
            HetznerFixtures.action(command: "set_rrset_records"),
            HetznerFixtures.json(#"{"rrset":{"id":"www/A","name":"www","type":"A","ttl":300,"labels":{},"protection":{"change":false},"records":[{"value":"198.51.100.2"},{"value":"203.0.113.5","comment":"Webserver"}],"zone":42}}"#),
        ])
        // Index 0 ist nach Sortierung 198.51.100.1 (mit Kommentar), nicht der erste Eintrag der Antwort.
        let record = try await adapter.updateRecord(zone: "example.com", providerRef: "www/A/0", content: "203.0.113.5", ttl: nil, priority: nil)
        #expect(record.content == "203.0.113.5")
        #expect(record.ref.providerRef == "www/A/1")
        #expect(record.extra["comment"] == .string("Webserver"))
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(requests[1].path == "/zones/example.com/rrsets/www/A/actions/set_records")
        #expect(requests[1].body == .object(["records": .array([
            .object(["value": .string("203.0.113.5"), "comment": .string("Webserver")]),
            .object(["value": .string("198.51.100.2")]),
        ])]))
    }

    @Test func updateRecordChangesOnlyTTL() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            try HetznerFixtures.ok("rrset-www-a"),
            HetznerFixtures.action(command: "change_rrset_ttl"),
            HetznerFixtures.json(#"{"rrset":{"id":"www/A","name":"www","type":"A","ttl":60,"labels":{},"protection":{"change":false},"records":[{"value":"198.51.100.2"},{"value":"198.51.100.1"}],"zone":42}}"#),
        ])
        let record = try await adapter.updateRecord(zone: "example.com", providerRef: "www/A/1", content: nil, ttl: 60, priority: nil)
        #expect(record.content == "198.51.100.2")
        #expect(record.ttl == 60)
        let requests = await transport.requests
        #expect(requests.map(\.path) == ["/zones/example.com/rrsets/www/A", "/zones/example.com/rrsets/www/A/actions/change_ttl", "/zones/example.com/rrsets/www/A"])
        #expect(requests[1].body == .object(["ttl": .int(60)]))
    }

    @Test func updateRecordPriorityOnlyForMX() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            HetznerFixtures.json(#"{"rrset":{"id":"@/MX","name":"@","type":"MX","ttl":7200,"labels":{},"protection":{"change":false},"records":[{"value":"10 mail.example.com."}],"zone":42}}"#),
            HetznerFixtures.action(command: "set_rrset_records"),
            HetznerFixtures.json(#"{"rrset":{"id":"@/MX","name":"@","type":"MX","ttl":7200,"labels":{},"protection":{"change":false},"records":[{"value":"20 mail.example.com."}],"zone":42}}"#),
        ])
        let record = try await adapter.updateRecord(zone: "example.com", providerRef: "@/mx/0", content: nil, ttl: nil, priority: 20)
        #expect(record.content == "20 mail.example.com.")
        let requests = await transport.requests
        #expect(requests[1].body == .object(["records": .array([.object(["value": .string("20 mail.example.com.")])])]))
    }

    @Test func updateRecordWithSameValueSkipsWrite() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            try HetznerFixtures.ok("rrset-www-a"),
            try HetznerFixtures.ok("rrset-www-a"),
        ])
        let record = try await adapter.updateRecord(zone: "example.com", providerRef: "www/A/0", content: "198.51.100.1", ttl: 300, priority: nil)
        #expect(record.ref.providerRef == "www/A/0")
        #expect(await transport.requests.map(\.method) == ["GET", "GET"])
    }

    @Test func updateRecordUnknownIndexIsNotFound() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("rrset-www-a")])
        await #expect(throws: KastellanError.notFound("DNS-Record www/A/5 in Zone example.com")) {
            try await adapter.updateRecord(zone: "example.com", providerRef: "www/A/5", content: "1.2.3.4", ttl: nil, priority: nil)
        }
    }

    @Test func updateRecordMissingRRSetIsNotFound() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([HetznerFixtures.notFound("rrset")])
        await #expect(throws: KastellanError.notFound("DNS-Record mail/A/0 in Zone example.com")) {
            try await adapter.updateRecord(zone: "example.com", providerRef: "mail/A/0", content: "1.2.3.4", ttl: nil, priority: nil)
        }
    }

    @Test func malformedProviderRefIsInvalidArgument() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([])
        await #expect(throws: KastellanError.invalidArgument("provider_ref www/A hat nicht die Form name/type/index")) {
            try await adapter.deleteRecord(zone: "example.com", providerRef: "www/A")
        }
        await #expect(throws: KastellanError.invalidArgument("provider_ref www/A/x hat nicht die Form name/type/index")) {
            try await adapter.deleteRecord(zone: "example.com", providerRef: "www/A/x")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func deleteRecordRemovesOneValue() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            try HetznerFixtures.ok("rrset-www-a"),
            HetznerFixtures.action(command: "remove_rrset_records"),
        ])
        try await adapter.deleteRecord(zone: "example.com", providerRef: "www/A/1")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "POST"])
        #expect(requests[1].path == "/zones/example.com/rrsets/www/A/actions/remove_records")
        #expect(requests[1].body == .object(["records": .array([.object(["value": .string("198.51.100.2")])])]))
    }

    @Test func deleteLastRecordDeletesRRSet() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            HetznerFixtures.json(#"{"rrset":{"id":"@/MX","name":"@","type":"MX","ttl":7200,"labels":{},"protection":{"change":false},"records":[{"value":"10 mail.example.com."}],"zone":42}}"#),
            HetznerFixtures.action(command: "delete_rrset", status: "running"),
            try HetznerFixtures.ok("action-success"),
        ])
        try await adapter.deleteRecord(zone: "example.com", providerRef: "@/MX/0")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "DELETE", "GET"])
        #expect(requests[1].path == "/zones/example.com/rrsets/@/MX")
        #expect(requests[2].path == "/actions/1")
    }

    @Test func deleteRecordFailedActionIsProviderError() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([
            try HetznerFixtures.ok("rrset-www-a"),
            HetznerFixtures.action(command: "remove_rrset_records", status: "error", error: ("protected", "rrset is protected")),
        ])
        await #expect(throws: KastellanError.provider("remove_rrset_records: protected: rrset is protected")) {
            try await adapter.deleteRecord(zone: "example.com", providerRef: "www/A/0")
        }
    }

    @Test func applyChangesRunsSequentially() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            HetznerFixtures.notFound("rrset"),
            HetznerFixtures.action(command: "create_rrset"),
            HetznerFixtures.json(#"{"rrset":{"id":"api/A","name":"api","type":"A","ttl":null,"labels":{},"protection":{"change":false},"records":[{"value":"203.0.113.10"}],"zone":42}}"#),
            try HetznerFixtures.ok("rrset-www-a"),
            HetznerFixtures.action(command: "remove_rrset_records"),
        ])
        let touched = try await adapter.applyChanges(zone: "example.com", changes: [
            .create(name: "api", type: "A", content: "203.0.113.10", ttl: nil, priority: nil),
            .delete(providerRef: "www/A/0"),
        ])
        #expect(touched.map(\.ref.providerRef) == ["api/A/0"])
        #expect(await transport.requests.count == 5)
    }

    // MARK: - Helfer

    @Test func rrsetNameNormalisesToZoneRelative() {
        #expect(HetznerAdapter.rrsetName("", zone: "example.com") == "@")
        #expect(HetznerAdapter.rrsetName("@", zone: "example.com") == "@")
        #expect(HetznerAdapter.rrsetName("example.com", zone: "example.com") == "@")
        #expect(HetznerAdapter.rrsetName("example.com.", zone: "Example.com") == "@")
        #expect(HetznerAdapter.rrsetName("WWW", zone: "example.com") == "www")
        #expect(HetznerAdapter.rrsetName("www.example.com", zone: "example.com") == "www")
        #expect(HetznerAdapter.rrsetName("a.b.example.com.", zone: "example.com") == "a.b")
        #expect(HetznerAdapter.rrsetName("*.example.com", zone: "example.com") == "*")
        #expect(HetznerAdapter.rrsetName("notexample.com", zone: "example.com") == "notexample.com")
    }

    @Test func priorityHelpersSplitMXAndSRV() {
        #expect(HetznerAdapter.value(content: "mail.example.com.", priority: 10, type: "MX") == "10 mail.example.com.")
        #expect(HetznerAdapter.value(content: "1 443 host.example.com.", priority: 5, type: "SRV") == "5 1 443 host.example.com.")
        #expect(HetznerAdapter.value(content: "1.2.3.4", priority: 10, type: "A") == "1.2.3.4")
        #expect(HetznerAdapter.priority(of: "10 mail.example.com.", type: "MX") == 10)
        #expect(HetznerAdapter.priority(of: "10 mail.example.com.", type: "TXT") == nil)
        #expect(HetznerAdapter.content(of: "10 mail.example.com.", type: "MX") == "mail.example.com.")
        #expect(HetznerAdapter.content(of: "mail.example.com.", type: "MX") == "mail.example.com.")
    }
}

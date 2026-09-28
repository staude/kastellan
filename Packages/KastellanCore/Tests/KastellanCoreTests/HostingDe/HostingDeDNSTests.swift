import Foundation
import Testing
@testable import KastellanCore

struct HostingDeDNSTests {
    static func zoneLookup(status: String = "active") -> HostingDeResponse {
        HostingDeFixtures.page([#"{"id":"zc-1001","name":"example.com","nameUnicode":"example.com","status":"\#(status)"}"#], page: 1, totalPages: 1)
    }

    @Test func listZonesMapsConfigs() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("zoneconfigs-find")])
        let zones = try await adapter.listZones()
        #expect(zones.map(\.zone) == ["example.com", "xn--beispiel-mnchen-hsb.de"])
        #expect(zones[0].ref.providerRef == "zc-1001")
        #expect(zones[0].defaultTTL == 86400)
        #expect(zones[1].extra["nameUnicode"] == .string("beispiel-münchen.de"))
        #expect(zones[1].extra["dnsSecMode"] == .string("automatic"))
        let req = try #require(await transport.requests.first)
        #expect(req.method == "dns/zoneConfigsFind")
        #expect(req.param("sort") == nil)
    }

    @Test func listRecordsUsesZoneIdAndRelativeNames() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([Self.zoneLookup(), try HostingDeFixtures.ok("records-find")])
        let records = try await adapter.listRecords(zone: "Example.com.")
        #expect(records.map(\.name) == ["@", "@", "@", "www"])
        #expect(records.map(\.type) == ["A", "MX", "TXT", "CNAME"])
        #expect(records[1].priority == 10)
        #expect(records[2].content == "\"v=spf1 mx -all\"")
        #expect(records[3].ref.providerRef == "rec-3")
        let requests = await transport.requests
        #expect(requests[0].method == "dns/zoneConfigsFind")
        #expect(requests[0].param("filter") == HostingDeFilter.or([.equal("ZoneName", "example.com"), .equal("ZoneNameUnicode", "example.com")]).json)
        #expect(requests[1].method == "dns/recordsFind")
        #expect(requests[1].param("filter") == HostingDeFilter.equal("ZoneConfigId", "zc-1001").json)
    }

    @Test func unknownZoneIsNotFound() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([HostingDeFixtures.page([], page: 1, totalPages: 0, totalEntries: 0)])
        await #expect(throws: KastellanError.notFound("DNS-Zone nope.example bei hosting.de")) {
            try await adapter.listRecords(zone: "nope.example")
        }
    }

    @Test func createRecordBuildsFQDNQuotesTXTAndRaisesTTL() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([Self.zoneLookup(), try HostingDeFixtures.ok("records-update-success")])
        let record = try await adapter.createRecord(zone: "example.com", name: "_kastellan", type: "txt", content: "probe", ttl: 10, priority: nil)
        #expect(record.name == "_kastellan")
        #expect(record.type == "TXT")
        #expect(record.ref.providerRef == "rec-9")
        let update = await transport.requests[1]
        #expect(update.method == "dns/recordsUpdate")
        #expect(update.param("zoneConfigId") == .string("zc-1001"))
        #expect(update.param("recordsToAdd") == .array([.object([
            "name": .string("_kastellan.example.com"), "type": .string("TXT"), "content": .string("\"probe\""), "ttl": .int(60),
        ])]))
        #expect(update.param("recordsToModify") == nil)
        #expect(update.param("recordsToDelete") == nil)
    }

    @Test func updateRecordReadsExistingAndSendsFullRecord() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            Self.zoneLookup(),
            Self.zoneLookup(), try HostingDeFixtures.ok("records-find"),
            HostingDeFixtures.json(#"{"status":"success","errors":[],"warnings":[],"metadata":{},"response":{"zoneConfig":{"id":"zc-1001","status":"active"},"records":[{"id":"rec-3","zoneId":"zc-1001","name":"www.example.com","type":"CNAME","content":"app.example.net","ttl":300}]}}"#),
        ])
        let record = try await adapter.updateRecord(zone: "example.com", providerRef: "rec-3", content: "app.example.net", ttl: nil, priority: nil)
        #expect(record.content == "app.example.net")
        #expect(record.name == "www")
        let update = await transport.requests[3]
        #expect(update.param("recordsToModify") == .array([.object([
            "id": .string("rec-3"), "name": .string("www.example.com"), "type": .string("CNAME"), "content": .string("app.example.net"), "ttl": .int(300),
        ])]))
    }

    @Test func updateUnknownRecordIsNotFound() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([Self.zoneLookup(), Self.zoneLookup(), try HostingDeFixtures.ok("records-find")])
        await #expect(throws: KastellanError.notFound("DNS-Record rec-404 in Zone example.com")) {
            try await adapter.updateRecord(zone: "example.com", providerRef: "rec-404", content: "x", ttl: nil, priority: nil)
        }
    }

    @Test func deleteRecordSendsRecordsToDelete() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([Self.zoneLookup(), try HostingDeFixtures.ok("records-update-success")])
        try await adapter.deleteRecord(zone: "example.com", providerRef: "rec-9")
        let update = await transport.requests[1]
        #expect(update.method == "dns/recordsUpdate")
        #expect(update.param("recordsToDelete") == .array([.object(["id": .string("rec-9")])]))
    }

    @Test func applyChangesBatchesAllListsAndWaitsWhenPending() async throws {
        let (adapter, transport, sleeps) = HostingDeFixtures.adapter([
            Self.zoneLookup(),
            Self.zoneLookup(), try HostingDeFixtures.ok("records-find"),
            try HostingDeFixtures.ok("zone-update-pending"),
            Self.zoneLookup(status: "blocked"),
            Self.zoneLookup(status: "active"),
            try HostingDeFixtures.ok("records-find"),
        ])
        let records = try await adapter.applyChanges(zone: "example.com", changes: [
            .create(name: "@", type: "AAAA", content: "2001:db8::1", ttl: nil, priority: nil),
            .update(providerRef: "rec-2", content: "mx2.example.com", ttl: nil, priority: 20),
            .delete(providerRef: "rec-4"),
        ])
        #expect(records.count == 4)
        let update = await transport.requests[3]
        #expect(update.method == "dns/recordsUpdate")
        #expect(update.param("recordsToAdd") == .array([.object(["name": .string("example.com"), "type": .string("AAAA"), "content": .string("2001:db8::1"), "ttl": .int(3600)])]))
        #expect(update.param("recordsToModify") == .array([.object(["id": .string("rec-2"), "name": .string("example.com"), "type": .string("MX"), "content": .string("mx2.example.com"), "ttl": .int(3600), "priority": .int(20)])]))
        #expect(update.param("recordsToDelete") == .array([.object(["id": .string("rec-4")])]))
        #expect(await sleeps.seconds == [1])
        let requests = await transport.requests
        #expect(requests.count == 7)
        #expect(requests[4].param("filter") == HostingDeFilter.equal("ZoneConfigId", "zc-1001").json)
    }

    @Test func blockedZoneIsAwaitedBeforeWriting() async throws {
        let (adapter, transport, sleeps) = HostingDeFixtures.adapter([
            Self.zoneLookup(status: "blocked"),
            Self.zoneLookup(status: "blocked"),
            Self.zoneLookup(status: "active"),
            try HostingDeFixtures.ok("records-update-success"),
        ])
        try await adapter.deleteRecord(zone: "example.com", providerRef: "rec-9")
        #expect(await sleeps.seconds == [1])
        #expect(await transport.requests.count == 4)
    }

    @Test func nameHelpers() {
        #expect(HostingDeAdapter.fqdn("@", zone: "example.com") == "example.com")
        #expect(HostingDeAdapter.fqdn("", zone: "example.com") == "example.com")
        #expect(HostingDeAdapter.fqdn("www", zone: "Example.com") == "www.example.com")
        #expect(HostingDeAdapter.fqdn("www.example.com.", zone: "example.com") == "www.example.com")
        #expect(HostingDeAdapter.relativeName("example.com", zone: "example.com") == "@")
        #expect(HostingDeAdapter.relativeName("a.b.example.com", zone: "example.com") == "a.b")
        #expect(HostingDeAdapter.content("v=spf1 -all", type: "TXT") == "\"v=spf1 -all\"")
        #expect(HostingDeAdapter.content("\"already\"", type: "TXT") == "\"already\"")
        #expect(HostingDeAdapter.content("192.0.2.1 ", type: "A") == "192.0.2.1")
    }

    @Test func capabilitiesDeclareDNS() {
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.dnsZone, .list)))
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.dnsRecord, .delete)))
        #expect(!HostingDeAdapter.capabilityMatrix.supports(Capability(.dnsZone, .create)))
    }
}

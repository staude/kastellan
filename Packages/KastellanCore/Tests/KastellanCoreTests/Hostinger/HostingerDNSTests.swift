import Foundation
import Testing
@testable import KastellanCore

struct HostingerDNSTests {
    static let zone = #"[{"name":"@","type":"A","ttl":14400,"records":[{"content":"192.0.2.10","is_disabled":false}]},{"name":"@","type":"MX","ttl":14400,"records":[{"content":"20 mx2.example.net","is_disabled":false},{"content":"10 mx1.example.net","is_disabled":false}]},{"name":"@","type":"TXT","ttl":3600,"records":[{"content":"v=spf1 include:example.net -all","is_disabled":false}]},{"name":"www","type":"CNAME","ttl":300,"records":[{"content":"example.com","is_disabled":false}]},{"name":"@","type":"NS","ttl":86400,"records":[{"content":"ns1.dns-parking.com","is_disabled":false},{"content":"ns2.dns-parking.com","is_disabled":false}]}]"#
    static let details = #"{"domain":"example.com","status":"active","is_privacy_protection_allowed":true,"is_privacy_protected":true,"is_lockable":true,"is_locked":true,"name_servers":{"ns1":"ns1.dns-parking.com","ns2":"ns2.dns-parking.com"},"child_name_servers":[],"domain_contacts":{"owner_id":1,"admin_id":1,"billing_id":1,"tech_id":1},"created_at":"2025-01-01T00:00:00Z","registered_at":"2025-01-01T00:00:00Z","expires_at":"2027-01-01T00:00:00Z"}"#

    @Test func listDomainsAndDetails() async throws {
        let (adapter, _, _) = HostingerFixtures.adapter([
            try HostingerFixtures.ok("portfolio"),
            HostingerFixtures.json(Self.details), HostingerFixtures.json(#"{"domain":"example.com","redirect_type":"301","redirect_url":"https://example.org/"}"#),
        ])
        let domains = try await adapter.listDomains()
        #expect(domains.map(\.fqdn) == ["example.com", "example.net"])
        #expect(domains[0].ref.providerRef == "1001")
        #expect(domains[1].status == "pending_setup")
        let detail = try #require(try await adapter.getDomain(fqdn: "Example.com"))
        #expect(detail.nameservers == ["ns1.dns-parking.com", "ns2.dns-parking.com"])
        #expect(detail.dnsManagedHere)
        #expect(detail.extra["is_locked"] == .bool(true))
        #expect(detail.extra["forwarding"]?.string("url") == "https://example.org/")
    }

    @Test func updateDomainNameserversLockPrivacyForwarding() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            HostingerFixtures.message(), HostingerFixtures.message(), HostingerFixtures.message(),
            HostingerFixtures.json(#"{"message":"Not found"}"#, status: 404),
            HostingerFixtures.json(#"{"domain":"example.com","redirect_type":"302","redirect_url":"https://example.org/"}"#),
            HostingerFixtures.json(Self.details), HostingerFixtures.json(#"{"domain":"example.com","redirect_type":"302","redirect_url":"https://example.org/"}"#),
        ])
        _ = try await adapter.updateDomain(fqdn: "example.com", path: nil, extra: [
            "nameservers": .array([.string("ns1.example.org"), .string("ns2.example.org")]), "lock": .bool(false), "privacy": .bool(true),
            "forward_url": .string("https://example.org/"), "redirect_type": .string("302"),
        ])
        let requests = await transport.requests
        #expect(requests[0].method == "PUT" && requests[0].path == "/api/domains/v1/portfolio/example.com/nameservers")
        #expect(requests[0].body == .object(["ns1": .string("ns1.example.org"), "ns2": .string("ns2.example.org")]))
        #expect(requests[1].method == "DELETE" && requests[1].path.hasSuffix("/domain-lock"))
        #expect(requests[2].method == "PUT" && requests[2].path.hasSuffix("/privacy-protection"))
        #expect(requests[3].method == "GET" && requests[3].path == "/api/domains/v1/forwarding/example.com")
        #expect(requests[4].method == "POST" && requests[4].path == "/api/domains/v1/forwarding")
        #expect(requests[4].body?.string("redirect_type") == "302")
    }

    @Test func listZonesAndRecordsSplitRRSets() async throws {
        let (adapter, _, _) = HostingerFixtures.adapter([try HostingerFixtures.ok("portfolio"), HostingerFixtures.json(Self.zone)])
        let zones = try await adapter.listZones()
        #expect(zones.map(\.zone) == ["example.com", "example.net"])
        let records = try await adapter.listRecords(zone: "example.com")
        #expect(records.map { "\($0.name) \($0.type) \($0.content)" } == ["@ A 192.0.2.10", "@ MX mx1.example.net", "@ MX mx2.example.net", "@ NS ns1.dns-parking.com", "@ NS ns2.dns-parking.com", "@ TXT v=spf1 include:example.net -all", "www CNAME example.com"])
        #expect(records[1].priority == 10 && records[1].ref.providerRef == "@/MX/0")
        #expect(records[2].priority == 20 && records[2].ref.providerRef == "@/MX/1")
        #expect(records[6].ttl == 300)
    }

    @Test func createRecordValidatesThenPutsWholeSetWithSnapshot() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            HostingerFixtures.json(Self.zone),
            HostingerFixtures.json(#"[{"id":7,"reason":"api","created_at":"2026-09-01T00:00:00Z"},{"id":9,"reason":"api","created_at":"2026-09-09T00:00:00Z"}]"#),
            HostingerFixtures.message("valid"), HostingerFixtures.message("updated"),
            HostingerFixtures.json(Self.zone.replacingOccurrences(of: #"[{"content":"v=spf1 include:example.net -all","is_disabled":false}]"#, with: #"[{"content":"_kastellan=probe","is_disabled":false},{"content":"v=spf1 include:example.net -all","is_disabled":false}]"#)),
        ])
        let record = try await adapter.createRecord(zone: "Example.com", name: "@", type: "txt", content: "_kastellan=probe", ttl: 300, priority: nil)
        #expect(record.content == "_kastellan=probe")
        #expect(record.ref.providerRef == "@/TXT/0")
        #expect(record.extra["snapshot_before"] == .int(9))
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "GET", "POST", "PUT", "GET"])
        #expect(requests[1].path == "/api/dns/v1/snapshots/example.com")
        #expect(requests[2].path == "/api/dns/v1/zones/example.com/validate")
        #expect(requests[3].path == "/api/dns/v1/zones/example.com")
        let body = try #require(requests[3].body)
        #expect(body["overwrite"] == .bool(true))
        #expect(body.array("zone") == [.object(["name": .string("@"), "type": .string("TXT"), "ttl": .int(300), "records": .array([.object(["content": .string("v=spf1 include:example.net -all")]), .object(["content": .string("_kastellan=probe")])])])])
        #expect(requests[2].body == body)
    }

    @Test func validationFailureStopsBeforeWrite() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            HostingerFixtures.json(Self.zone), HostingerFixtures.json("[]"),
            HostingerFixtures.json(#"{"message":"Validation failed","errors":{"zone.0.records.0.content":["invalid"]},"correlation_id":"c"}"#, status: 422),
        ])
        await #expect(throws: KastellanError.self) { try await adapter.createRecord(zone: "example.com", name: "@", type: "A", content: "kaputt", ttl: nil, priority: nil) }
        #expect(await transport.requests.count == 3)
    }

    @Test func updateMXPriorityAndDeleteLastValueRemovesSet() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            HostingerFixtures.json(Self.zone), HostingerFixtures.json("[]"), HostingerFixtures.message(), HostingerFixtures.message(), HostingerFixtures.json(Self.zone),
            HostingerFixtures.json(Self.zone), HostingerFixtures.json("[]"), HostingerFixtures.message(), HostingerFixtures.json(Self.zone),
        ])
        _ = try await adapter.updateRecord(zone: "example.com", providerRef: "@/MX/1", content: nil, ttl: nil, priority: 30)
        let put = await transport.requests[3]
        #expect(put.body?.array("zone").first?.array("records") == [.object(["content": .string("10 mx1.example.net")]), .object(["content": .string("30 mx2.example.net")])])
        try await adapter.deleteRecord(zone: "example.com", providerRef: "www/CNAME/0")
        let del = await transport.requests[7]
        #expect(del.method == "DELETE" && del.path == "/api/dns/v1/zones/example.com")
        #expect(del.body == .object(["filters": .array([.object(["name": .string("www"), "type": .string("CNAME")])])]))
    }

    @Test func applyChangesBatchesWritesAndDeletes() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            HostingerFixtures.json(Self.zone), HostingerFixtures.json("[]"), HostingerFixtures.message(), HostingerFixtures.message(), HostingerFixtures.message(), HostingerFixtures.json(Self.zone),
        ])
        _ = try await adapter.applyChanges(zone: "example.com", changes: [
            .create(name: "api.example.com", type: "A", content: "192.0.2.20", ttl: 600, priority: nil),
            .create(name: "@", type: "AAAA", content: "2001:db8::1", ttl: nil, priority: nil),
            .delete(providerRef: "@/TXT/0"),
        ])
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "GET", "POST", "PUT", "DELETE", "GET"])
        let zone = requests[3].body?.array("zone") ?? []
        #expect(zone.count == 2)
        #expect(zone.contains(.object(["name": .string("api"), "type": .string("A"), "ttl": .int(600), "records": .array([.object(["content": .string("192.0.2.20")])])])))
        #expect(zone.contains(.object(["name": .string("@"), "type": .string("AAAA"), "records": .array([.object(["content": .string("2001:db8::1")])])])))
        #expect(requests[4].body?.array("filters") == [.object(["name": .string("@"), "type": .string("TXT")])])
    }

    @Test func errorsForUnknownRefsAndDuplicates() async throws {
        let (adapter, _, _) = HostingerFixtures.adapter([HostingerFixtures.json(Self.zone), HostingerFixtures.json(Self.zone)])
        await #expect(throws: KastellanError.notFound("DNS-Record @/TXT/5 in Zone example.com")) { try await adapter.deleteRecord(zone: "example.com", providerRef: "@/TXT/5") }
        await #expect(throws: KastellanError.self) { try await adapter.createRecord(zone: "example.com", name: "@", type: "A", content: "192.0.2.10", ttl: nil, priority: nil) }
        #expect(HostingerAdapter.capabilityMatrix.supports(Capability(.dnsRecord, .delete)))
        #expect(!HostingerAdapter.capabilityMatrix.supports(Capability(.dnsZone, .create)))
    }
}

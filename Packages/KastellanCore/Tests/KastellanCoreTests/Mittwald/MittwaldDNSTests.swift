import Foundation
import Testing
@testable import KastellanCore

struct MittwaldDNSTests {
    static let project = "11111111-1111-4111-8111-111111111111"
    static let settings = ["project_id": project]
    static let zoneID = "z1111111-1111-4111-8111-111111111111"
    static func zonePage() throws -> MittwaldResponse {
        MittwaldFixtures.page([String(data: try MittwaldFixtures.data("dns-zone"), encoding: .utf8)!], total: 1)
    }
    static func zoneObject() throws -> MittwaldResponse {
        MittwaldFixtures.json(String(data: try MittwaldFixtures.data("dns-zone"), encoding: .utf8)!)
    }

    @Test func createTXTWritesWholeSetAndReloads() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            try Self.zonePage(),
            MittwaldFixtures.empty(status: 204, headers: ["etag": "9"]),
            MittwaldFixtures.json(#"{"id":"\#(Self.zoneID)","domain":"example.com","recordSet":{"combinedARecords":{},"mx":{},"txt":{"entries":["_kastellan=probe","neu=1","v=spf1 include:example.net -all"],"settings":{"ttl":{"seconds":300}}},"srv":{},"cname":{},"caa":{}}}"#),
        ], settings: Self.settings)
        let record = try await adapter.createRecord(zone: "example.com", name: "@", type: "txt", content: "\"neu=1\"", ttl: 300, priority: nil)
        #expect(record.type == "TXT" && record.content == "neu=1" && record.ttl == 300)
        #expect(record.ref.providerRef == "\(Self.zoneID)/TXT/1")
        let requests = await transport.requests
        #expect(requests[1].method == "PUT")
        #expect(requests[1].path == "/dns-zones/\(Self.zoneID)/record-sets/txt")
        #expect(requests[1].body?.strings("entries") == ["_kastellan=probe", "v=spf1 include:example.net -all", "neu=1"])
        #expect(requests[1].body?["settings"] == .object(["ttl": .object(["seconds": .int(300)])]))
        #expect(requests[2].method == "GET" && requests[2].path == "/dns-zones/\(Self.zoneID)")
        #expect(requests[2].headers["if-event-reached"] == "9")
    }

    @Test func updateMXChangesPriorityAndKeepsTTL() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([try Self.zonePage(), MittwaldFixtures.empty(), try Self.zoneObject()], settings: Self.settings)
        _ = try await adapter.updateRecord(zone: "example.com", providerRef: "\(Self.zoneID)/MX/1", content: nil, ttl: nil, priority: 30)
        let put = await transport.requests[1]
        #expect(put.path.hasSuffix("/record-sets/mx"))
        #expect(put.body?.array("records") == [.object(["fqdn": .string("mx1.example.net"), "priority": .int(10)]), .object(["fqdn": .string("mx2.example.net"), "priority": .int(30)])])
        #expect(put.body?["settings"]?["ttl"]?.int("seconds") == 3600)
    }

    @Test func deleteLastSRVUnsetsSet() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([try Self.zonePage(), MittwaldFixtures.empty(), try Self.zoneObject()], settings: Self.settings)
        try await adapter.deleteRecord(zone: "example.com", providerRef: "\(Self.zoneID)/SRV/0")
        let put = await transport.requests[1]
        #expect(put.path.hasSuffix("/record-sets/srv"))
        #expect(put.body == .object([:]))
    }

    @Test func createAAAAOnManagedSetBecomesCustomWithNote() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            try Self.zonePage(), MittwaldFixtures.empty(),
            MittwaldFixtures.json(#"{"id":"\#(Self.zoneID)","domain":"example.com","recordSet":{"combinedARecords":{"a":[],"aaaa":["2001:db8::1"],"settings":{"ttl":{"auto":true}}},"mx":{},"txt":{},"srv":{},"cname":{},"caa":{}}}"#),
        ], settings: Self.settings)
        let record = try await adapter.createRecord(zone: "example.com", name: "example.com", type: "AAAA", content: "2001:db8::1", ttl: nil, priority: nil)
        #expect(record.type == "AAAA")
        #expect(record.extra["note"]?.stringValue?.contains("verwaltet") == true)
        let put = await transport.requests[1]
        #expect(put.path.hasSuffix("/record-sets/a"))
        #expect(put.body == .object(["a": .array([]), "aaaa": .array([.string("2001:db8::1")]), "settings": .object(["ttl": .object(["auto": .bool(true)])])]))
    }

    @Test func applyChangesWritesOnePutPerSet() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([try Self.zonePage(), MittwaldFixtures.empty(), MittwaldFixtures.empty(), try Self.zoneObject()], settings: Self.settings)
        _ = try await adapter.applyChanges(zone: "example.com", changes: [
            .create(name: "@", type: "TXT", content: "a=1", ttl: nil, priority: nil),
            .create(name: "@", type: "CAA", content: "0 issuewild \"letsencrypt.org\"", ttl: nil, priority: nil),
            .delete(providerRef: "\(Self.zoneID)/TXT/0"),
        ])
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "PUT", "PUT", "GET"])
        #expect(requests[1].path.hasSuffix("/caa"))
        #expect(requests[1].body?.array("records").count == 2)
        #expect(requests[2].path.hasSuffix("/txt"))
        #expect(requests[2].body?.strings("entries") == ["v=spf1 include:example.net -all", "a=1"])
    }

    @Test func validationErrors() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([try Self.zonePage(), try Self.zonePage(), try Self.zonePage(), try Self.zonePage()], settings: Self.settings)
        await #expect(throws: KastellanError.self) { try await adapter.createRecord(zone: "example.com", name: "www", type: "A", content: "192.0.2.1", ttl: nil, priority: nil) }
        await #expect(throws: KastellanError.self) { try await adapter.createRecord(zone: "example.com", name: "@", type: "NS", content: "ns.example.org", ttl: nil, priority: nil) }
        await #expect(throws: KastellanError.self) { try await adapter.createRecord(zone: "example.com", name: "@", type: "SRV", content: "kaputt", ttl: nil, priority: nil) }
        await #expect(throws: KastellanError.notFound("DNS-Record \(Self.zoneID)/TXT/9 in Zone example.com")) { try await adapter.deleteRecord(zone: "example.com", providerRef: "\(Self.zoneID)/TXT/9") }
    }

    @Test func setBodyHelpers() throws {
        #expect(try MittwaldAdapter.setBody("cname", values: [.init(type: "CNAME", content: "target.example.net", priority: nil)], ttl: 20) == .object(["fqdn": .string("target.example.net"), "settings": .object(["ttl": .object(["seconds": .int(60)])])]))
        #expect(try MittwaldAdapter.setBody("srv", values: [.init(type: "SRV", content: "5 5060 sip.example.com", priority: 10)], ttl: nil).array("records").first == .object(["fqdn": .string("sip.example.com"), "port": .int(5060), "priority": .int(10), "weight": .int(5)]))
        #expect(throws: KastellanError.self) { try MittwaldAdapter.setBody("cname", values: [.init(type: "CNAME", content: "a", priority: nil), .init(type: "CNAME", content: "b", priority: nil)], ttl: nil) }
        #expect(MittwaldAdapter.capabilityMatrix.supports(Capability(.dnsRecord, .create)))
    }
}

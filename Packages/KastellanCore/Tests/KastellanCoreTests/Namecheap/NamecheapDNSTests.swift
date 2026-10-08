import Foundation
import Testing
@testable import KastellanCore

struct NamecheapDNSTests {
    static func setOK(_ domain: String) -> NamecheapResponse {
        NamecheapFixtures.response("namecheap.domains.dns.setHosts", #"<DomainDNSSetHostsResult Domain="\#(domain)" IsSuccess="true"><Warnings /></DomainDNSSetHostsResult>"#)
    }

    static func hosts(_ domain: String, emailType: String, _ hosts: String) -> NamecheapResponse {
        NamecheapFixtures.response("namecheap.domains.dns.getHosts", #"<DomainDNSGetHostsResult Domain="\#(domain)" EmailType="\#(emailType)" IsUsingOurDNS="true">\#(hosts)</DomainDNSGetHostsResult>"#)
    }

    /// Alle `host`-Elemente einer Fixture als (Name, Typ, Adresse, MXPref, TTL).
    static func fixtureHosts(_ name: String) throws -> [[String]] {
        let root = try NamecheapXMLElement.parse(try NamecheapFixtures.data(name))
        return root.descendants("host").map { [$0["Name"]!, $0["Type"]!, $0["Address"]!, $0["MXPref"]!, $0["TTL"]!] }
    }

    static func written(_ request: NamecheapRecordedRequest) -> [[String]] {
        var out: [[String]] = []
        var n = 1
        while let name = request.value("HostName\(n)") {
            out.append([name, request.value("RecordType\(n)")!, request.value("Address\(n)")!, request.value("MXPref\(n)")!, request.value("TTL\(n)")!])
            n += 1
        }
        return out
    }

    @Test func listZonesOnlyWithNamecheapDNS() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([try NamecheapFixtures.ok("domains-getlist")])
        let zones = try await adapter.listZones()
        #expect(zones.count == 31)
        #expect(zones.allSatisfy { $0.defaultTTL == 1800 })
    }

    @Test func listRecordsFromRealFixture() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([try NamecheapFixtures.ok("domains-dns-gethosts-example33-com")])
        let records = try await adapter.listRecords(zone: "Example33.com.")
        #expect(records.count == 20)
        let request = try #require(await transport.requests.first)
        #expect(request.value("SLD") == "example33" && request.value("TLD") == "com")
        let mx = try #require(records.first { $0.type == "MX" })
        #expect(mx.priority == 10)
        #expect(mx.ref.providerRef.hasPrefix("@/MX/"))
        #expect(Set(records.map(\.ref.providerRef)).count == 20)
        #expect(records.contains { $0.extra["email_type"] == .string("MX") })
    }

    @Test func duplicateRecordsGetDistinctRefs() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([try NamecheapFixtures.ok("domains-dns-gethosts-example29-com")])
        let records = try await adapter.listRecords(zone: "example29.com")
        let challenge = records.filter { $0.name.hasPrefix("_github-challenge") }
        #expect(challenge.count == 2)
        #expect(Set(challenge.map(\.ref.providerRef)).count == 2)
        #expect(challenge.contains { $0.ref.providerRef.hasSuffix("-2") })
        #expect(challenge.allSatisfy { $0.extra["warning"] != nil })
    }

    @Test func foreignNameserversAreRejected() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([try NamecheapFixtures.ok("domains-dns-gethosts-example13-com")])
        await #expect { _ = try await adapter.listRecords(zone: "example13.com") } throws: {
            if case .unsupported = $0 as? KastellanError { true } else { false }
        }
    }

    /// Kerntest: eine Zone ohne Änderung zurückschreiben ergibt exakt dieselben Records und denselben EmailType.
    @Test(arguments: ["example17", "example29", "example33"])
    func roundTripIsIdentical(_ domain: String) async throws {
        let fixture = "domains-dns-gethosts-\(domain)-com"
        let (adapter, transport) = NamecheapFixtures.adapter([try NamecheapFixtures.ok(fixture), Self.setOK("\(domain).com"), try NamecheapFixtures.ok(fixture)])
        _ = try await adapter.applyChanges(zone: "\(domain).com", changes: [])
        let set = try #require(await transport.requests.dropFirst().first)
        #expect(set.command == "namecheap.domains.dns.setHosts")
        #expect(set.value("EmailType") == "MX")
        #expect(Self.written(set) == (try Self.fixtureHosts(fixture)))
    }

    @Test func createTxtKeepsEverythingElseIncludingMXAndURL() async throws {
        let fixture = "domains-dns-gethosts-example17-com"
        let (adapter, transport) = NamecheapFixtures.adapter([
            try NamecheapFixtures.ok(fixture), Self.setOK("example17.com"),
            Self.hosts("example17.com", emailType: "MX", #"<host HostId="1" Name="_dmarc" Type="TXT" Address="v=DMARC1; p=none" MXPref="10" TTL="300" />"#),
        ])
        let created = try await adapter.createRecord(zone: "example17.com", name: "_dmarc.example17.com", type: "txt", content: "v=DMARC1; p=none", ttl: 300, priority: nil)
        #expect(created.name == "_dmarc")
        let set = try #require(await transport.requests.dropFirst().first)
        let written = Self.written(set)
        let original = try Self.fixtureHosts(fixture)
        #expect(Array(written.prefix(original.count)) == original)
        #expect(written.last == ["_dmarc", "TXT", "v=DMARC1; p=none", "10", "300"])
        #expect(written.contains { $0[1] == "MX" })
        #expect(written.contains { $0[1] == "URL" })
        #expect(set.value("EmailType") == "MX")
    }

    @Test func updateAndDeleteByRef() async throws {
        let fixture = "domains-dns-gethosts-example29-com"
        let (adapter, transport) = NamecheapFixtures.adapter([
            try NamecheapFixtures.ok(fixture), try NamecheapFixtures.ok(fixture), Self.setOK("example29.com"), try NamecheapFixtures.ok(fixture),
        ])
        let records = try await adapter.listRecords(zone: "example29.com")
        let www = try #require(records.first { $0.name == "www" && $0.type == "A" })
        let webmail = try #require(records.first { $0.name == "webmail" && $0.type == "AAAA" })
        _ = try await adapter.applyChanges(zone: "example29.com", changes: [
            .update(providerRef: www.ref.providerRef, content: "192.0.2.99", ttl: 600, priority: nil),
            .delete(providerRef: webmail.ref.providerRef),
        ])
        let written = Self.written(try #require(await transport.requests.dropFirst(2).first))
        #expect(written.count == 9)
        #expect(written.contains(["www", "A", "192.0.2.99", "10", "600"]))
        #expect(!written.contains { $0[0] == "webmail" && $0[1] == "AAAA" })
        #expect(written.contains { $0[0].hasPrefix("_github-challenge") && $0[0].hasSuffix(".example29.com") })
    }

    @Test func staleRefIsRejectedWithoutWriting() async throws {
        let fixture = "domains-dns-gethosts-example29-com"
        let (adapter, transport) = NamecheapFixtures.adapter([try NamecheapFixtures.ok(fixture)])
        await #expect { _ = try await adapter.applyChanges(zone: "example29.com", changes: [.delete(providerRef: "www/A/deadbeef")]) } throws: {
            if case .notFound(let m) = $0 as? KastellanError { m.contains("neu lesen") } else { false }
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func firstMXSwitchesEmailTypeToMX() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([
            Self.hosts("example.com", emailType: "NONE", ""), Self.setOK("example.com"),
            Self.hosts("example.com", emailType: "MX", #"<host HostId="1" Name="@" Type="MX" Address="mx.example.net." MXPref="5" TTL="1800" />"#),
        ])
        let mx = try await adapter.createRecord(zone: "example.com", name: "@", type: "MX", content: "mx.example.net.", ttl: nil, priority: 5)
        #expect(mx.priority == 5)
        let set = try #require(await transport.requests.dropFirst().first)
        #expect(set.value("EmailType") == "MX")
        #expect(set.value("MXPref1") == "5" && set.value("TTL1") == "1800")
    }

    @Test func emptyZoneWithoutMailTypeSendsNoEmailType() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([
            Self.hosts("example.com", emailType: "NONE", ""), Self.setOK("example.com"),
            Self.hosts("example.com", emailType: "NONE", #"<host HostId="1" Name="www" Type="A" Address="192.0.2.1" MXPref="10" TTL="1800" />"#),
        ])
        _ = try await adapter.createRecord(zone: "example.com", name: "www", type: "A", content: "192.0.2.1", ttl: nil, priority: nil)
        #expect(await transport.requests[1].value("EmailType") == nil)
    }

    @Test func duplicateCreateAndUnknownTypeAreRejected() async throws {
        let fixture = "domains-dns-gethosts-example29-com"
        let (adapter, _) = NamecheapFixtures.adapter([try NamecheapFixtures.ok(fixture), try NamecheapFixtures.ok(fixture)])
        await #expect(throws: KastellanError.self) { _ = try await adapter.createRecord(zone: "example29.com", name: "www", type: "A", content: "192.0.2.10", ttl: nil, priority: nil) }
        await #expect(throws: KastellanError.self) { _ = try await adapter.createRecord(zone: "example29.com", name: "x", type: "SRV", content: "0 5 5060 sip.example.com", ttl: nil, priority: nil) }
    }

    @Test func capabilities() {
        let m = NamecheapAdapter.capabilityMatrix
        #expect(m.supports(Capability(.dnsZone, .list)))
        for a in [Action.list, .create, .update, .delete] { #expect(m.supports(Capability(.dnsRecord, a))) }
        #expect(!m.supports(Capability(.dnsZone, .create)))
    }
}

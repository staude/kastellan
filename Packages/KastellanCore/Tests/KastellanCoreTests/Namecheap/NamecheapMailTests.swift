import Foundation
import Testing
@testable import KastellanCore

struct NamecheapMailTests {
    static func forwarding(_ domain: String, _ entries: [(String, String)]) -> NamecheapResponse {
        let inner = entries.map { #"<Forward mailbox="\#($0.0)">\#($0.1)</Forward>"# }.joined()
        return NamecheapFixtures.response("namecheap.domains.dns.getEmailForwarding", #"<DomainDNSGetEmailForwardingResult Domain="\#(domain)">\#(inner)</DomainDNSGetEmailForwardingResult>"#)
    }

    static let setOK = NamecheapFixtures.response("namecheap.domains.dns.setEmailForwarding", #"<DomainDNSSetEmailForwardingResult Domain="example.com" IsSuccess="true" />"#)
    static let fwdZone = NamecheapDNSTests.hosts("example.com", emailType: "FWD", "")
    static let mxZone = NamecheapDNSTests.hosts("example.com", emailType: "MX", #"<host HostId="1" Name="@" Type="MX" Address="mx.example.net." MXPref="10" TTL="1800" />"#)

    @Test func listGroupsTargetsAndMarksCatchAll() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([Self.fwdZone, Self.forwarding("example.com", [("info", "a@example.net"), ("info", "b@example.net"), ("*", "c@example.net")])])
        let list = try await adapter.listForwards(domain: "Example.com")
        #expect(list.map(\.address) == ["info@example.com", "*@example.com"])
        #expect(list[0].targets == ["a@example.net", "b@example.net"])
        #expect(list[0].status == .active)
        #expect(list[1].extra["catch_all"] == .bool(true))
    }

    @Test func listOnMXZoneMarksForwardsDisabled() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([Self.mxZone, Self.forwarding("example.com", [("info", "a@example.net")])])
        let list = try await adapter.listForwards(domain: "example.com")
        #expect(list[0].status == .disabled)
        #expect(list[0].extra["warning"] != nil)
    }

    @Test func emptyRealFixture() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([try NamecheapFixtures.ok("domains-dns-gethosts-example33-com"), try NamecheapFixtures.ok("domains-dns-getemailforwarding-example33-com")])
        #expect(try await adapter.listForwards(domain: "example33.com").isEmpty)
    }

    @Test func createAppendsAndKeepsOthers() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([
            Self.fwdZone, Self.forwarding("example.com", [("info", "a@example.net")]), Self.setOK,
            Self.forwarding("example.com", [("info", "a@example.net"), ("kontakt", "x@example.net"), ("kontakt", "y@example.net")]),
        ])
        let created = try await adapter.createForward(address: "Kontakt@example.com", targets: ["x@example.net", " y@example.net "], keepCopy: false)
        #expect(created.targets == ["x@example.net", "y@example.net"])
        let set = await transport.requests[2]
        #expect(set.command == "namecheap.domains.dns.setEmailForwarding")
        #expect(set.value("DomainName") == "example.com")
        #expect(set.value("MailBox1") == "info" && set.value("ForwardTo1") == "a@example.net")
        #expect(set.value("MailBox2") == "kontakt" && set.value("ForwardTo2") == "x@example.net")
        #expect(set.value("MailBox3") == "kontakt" && set.value("ForwardTo3") == "y@example.net")
        #expect(set.value("MailBox4") == nil)
    }

    @Test func updateReplacesTargetsInPlace() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([
            Self.fwdZone, Self.forwarding("example.com", [("a", "1@example.net"), ("info", "old@example.net"), ("z", "2@example.net")]), Self.setOK,
            Self.forwarding("example.com", [("a", "1@example.net"), ("info", "new@example.net"), ("z", "2@example.net")]),
        ])
        _ = try await adapter.updateForward(address: "info@example.com", targets: ["new@example.net"], keepCopy: false)
        let set = await transport.requests[2]
        #expect([set.value("MailBox1"), set.value("MailBox2"), set.value("MailBox3")] == ["a", "info", "z"])
        #expect(set.value("ForwardTo2") == "new@example.net")
    }

    @Test func deleteRemovesAllEntriesOfMailbox() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([
            Self.forwarding("example.com", [("info", "a@example.net"), ("info", "b@example.net"), ("z", "2@example.net")]), Self.setOK,
        ])
        try await adapter.deleteForward(address: "info@example.com")
        let set = await transport.requests[1]
        #expect(set.value("MailBox1") == "z" && set.value("MailBox2") == nil)
    }

    @Test func rejectsKeepCopyWrongEmailTypeAndBadInput() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([Self.mxZone])
        await #expect(throws: KastellanError.self) { _ = try await adapter.createForward(address: "info@example.com", targets: ["a@example.net"], keepCopy: true) }
        await #expect { _ = try await adapter.createForward(address: "info@example.com", targets: ["a@example.net"], keepCopy: false) } throws: {
            if case .unsupported(let m) = $0 as? KastellanError { m.contains("FWD") } else { false }
        }
        await #expect(throws: KastellanError.self) { _ = try await adapter.createForward(address: "kein-at", targets: ["a@example.net"], keepCopy: false) }
        await #expect(throws: KastellanError.self) { _ = try await adapter.createForward(address: "info@example.com", targets: ["kein-ziel"], keepCopy: false) }
        #expect(await transport.requests.count == 1)
    }

    @Test func capabilities() {
        for a in [Action.list, .create, .update, .delete] { #expect(NamecheapAdapter.capabilityMatrix.supports(Capability(.mailForward, a))) }
        #expect(!NamecheapAdapter.capabilityMatrix.supports(Capability(.mailbox, .list)))
    }
}

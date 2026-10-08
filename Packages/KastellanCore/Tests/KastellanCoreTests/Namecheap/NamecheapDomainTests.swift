import Foundation
import Testing
@testable import KastellanCore

struct NamecheapDomainTests {
    @Test func listDomainsFromRealFixture() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([try NamecheapFixtures.ok("domains-getlist")])
        let domains = try await adapter.listDomains()
        #expect(domains.count == 33)
        #expect(domains.map(\.fqdn) == domains.map(\.fqdn).sorted())
        #expect(domains.filter { !$0.dnsManagedHere }.count == 2)
        let first = try #require(domains.first { $0.fqdn == "example.com" })
        #expect(first.status == "active")
        #expect(first.extra["expires"] != nil)
        #expect(first.extra["auto_renew"] == .bool(true))
    }

    @Test func getDomainWithForeignNameserversAndPrivacy() async throws {
        // example13 ist eine .com-Domain mit fremden Nameservern und aktivem Privacy-Schutz.
        let (adapter, transport) = NamecheapFixtures.adapter([
            try NamecheapFixtures.ok("domains-getinfo-example13-com"),
            try NamecheapFixtures.ok("domains-getregistrarlock-example13-com"),
        ])
        let domain = try #require(try await adapter.getDomain(fqdn: "Example13.com"))
        #expect(domain.fqdn == "example13.com")
        #expect(!domain.dnsManagedHere)
        #expect(domain.nameservers.count == 4)
        #expect(domain.extra["privacy"] == .string("true"))
        #expect(domain.extra["privacy_id"] != nil)
        #expect(domain.extra["dns_provider_type"] == .string("CUSTOM"))
        #expect(domain.extra["is_locked"] != nil)
        #expect(await transport.requests.map(\.command) == ["namecheap.domains.getInfo", "namecheap.domains.getRegistrarLock"])
    }

    @Test func getDomainWithNamecheapDNS() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([
            try NamecheapFixtures.ok("domains-getinfo-example33-com"),
            try NamecheapFixtures.ok("domains-getregistrarlock-example33-com"),
        ])
        let domain = try #require(try await adapter.getDomain(fqdn: "example33.com"))
        #expect(domain.dnsManagedHere)
        #expect(domain.nameservers == ["dns1.registrar-servers.com", "dns2.registrar-servers.com"])
        #expect(domain.extra["is_locked"] == .bool(true))
    }

    @Test func deDomainsSkipLockLookup() async throws {
        let info = NamecheapFixtures.response("namecheap.domains.getInfo", #"<DomainGetInfoResult Status="Ok" ID="7" DomainName="example.de"><DomainDetails><CreatedDate>06/01/2026</CreatedDate><ExpiredDate>06/01/2027</ExpiredDate></DomainDetails><Whoisguard Enabled="NotAlloted"><ID>0</ID></Whoisguard><DnsDetails ProviderType="FREE" IsUsingOurDNS="true" HostCount="0" EmailType="No Email Service"><Nameserver>dns1.registrar-servers.com</Nameserver></DnsDetails></DomainGetInfoResult>"#)
        let (adapter, transport) = NamecheapFixtures.adapter([info])
        let domain = try #require(try await adapter.getDomain(fqdn: "example.de"))
        #expect(domain.extra["lock_supported"] == .bool(false))
        #expect(domain.extra["privacy_id"] == nil)
        #expect(await transport.requests.count == 1)
        await #expect(throws: KastellanError.unsupported("Namecheap: Für .de-Domains gibt es keinen Registrar-Lock")) {
            _ = try await adapter.updateDomain(fqdn: "example.de", path: nil, extra: ["lock": .bool(true)])
        }
    }

    @Test func getDomainNotFoundIsNil() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([NamecheapFixtures.error("2019166", "Domain not found")])
        #expect(try await adapter.getDomain(fqdn: "missing.example.com") == nil)
    }

    @Test func updateNameserversCustomAndDefault() async throws {
        let refreshed = [try NamecheapFixtures.ok("domains-getinfo-example33-com"), try NamecheapFixtures.ok("domains-getregistrarlock-example33-com")]
        let (adapter, transport) = NamecheapFixtures.adapter(
            [NamecheapFixtures.response("namecheap.domains.dns.setCustom", #"<DomainDNSSetCustomResult Domain="example33.com" Updated="true" />"#)] + refreshed
            + [NamecheapFixtures.response("namecheap.domains.dns.setDefault", #"<DomainDNSSetDefaultResult Domain="example33.com" Updated="true" />"#)] + refreshed)
        _ = try await adapter.updateDomain(fqdn: "example33.com", path: nil, extra: ["nameservers": .array([.string("NS1.example.org."), .string("ns2.example.org")])])
        _ = try await adapter.updateDomain(fqdn: "example33.com", path: nil, extra: ["nameservers": .string("default")])
        let requests = await transport.requests
        #expect(requests[0].command == "namecheap.domains.dns.setCustom")
        #expect(requests[0].value("SLD") == "example33" && requests[0].value("TLD") == "com")
        #expect(requests[0].value("Nameservers") == "ns1.example.org,ns2.example.org")
        #expect(requests[3].command == "namecheap.domains.dns.setDefault")
    }

    @Test func updateNameserversNeedsTwo() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([])
        await #expect(throws: KastellanError.self) {
            _ = try await adapter.updateDomain(fqdn: "example.com", path: nil, extra: ["nameservers": .array([.string("ns1.example.org")])])
        }
    }

    @Test func updateLockAndPrivacy() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([
            NamecheapFixtures.response("namecheap.domains.setRegistrarLock", #"<DomainSetRegistrarLockResult Domain="example13.com" IsSuccess="true" />"#),
            try NamecheapFixtures.ok("domains-getinfo-example13-com"),
            NamecheapFixtures.response("namecheap.whoisguard.disable", #"<WhoisguardDisableResult DomainName="example13.com" IsSuccess="true" />"#),
            try NamecheapFixtures.ok("domains-getinfo-example13-com"), try NamecheapFixtures.ok("domains-getregistrarlock-example13-com"),
        ])
        _ = try await adapter.updateDomain(fqdn: "example13.com", path: nil, extra: ["lock": .string("ja"), "privacy": .bool(false)])
        let requests = await transport.requests
        #expect(requests[0].command == "namecheap.domains.setRegistrarLock" && requests[0].value("LockAction") == "LOCK")
        #expect(requests[2].command == "namecheap.whoisguard.disable" && requests[2].value("WhoisguardID") != nil)
    }

    @Test func enablingPrivacyNeedsForwardEmail() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([try NamecheapFixtures.ok("domains-getinfo-example13-com")])
        await #expect(throws: KastellanError.self) {
            _ = try await adapter.updateDomain(fqdn: "example13.com", path: nil, extra: ["privacy": .bool(true)])
        }
    }

    @Test func createAndDeleteAreUnsupported() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([])
        await #expect(throws: KastellanError.self) { _ = try await adapter.createDomain(fqdn: "x.example.com", path: nil, extra: [:]) }
        await #expect(throws: KastellanError.self) { try await adapter.deleteDomain(fqdn: "example.com") }
        #expect(!NamecheapAdapter.capabilityMatrix.supports(Capability(.domain, .create)))
        #expect(!NamecheapAdapter.capabilityMatrix.supports(Capability(.domain, .delete)))
        #expect(NamecheapAdapter.capabilityMatrix.supports(Capability(.domain, .update)))
    }
}

import Foundation
import Testing
@testable import KastellanCore

struct HostingDeDomainTests {
    @Test func listDomainsMapsRegistrarObjects() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("domains-find")])
        let domains = try await adapter.listDomains()
        #expect(domains.map(\.fqdn) == ["example.com", "example.net"])
        #expect(domains[0].status == "ok")
        #expect(domains[0].nameservers == ["ns1.hosting.de", "ns2.hosting.de"])
        #expect(domains[0].dnsManagedHere)
        #expect(!domains[1].dnsManagedHere)
        #expect(domains[0].extra["transferLockEnabled"] == .bool(true))
        #expect(domains[1].extra["deletionType"] == .string("withdraw"))
        #expect(domains[0].extra["contacts"] == .array([.object(["type": .string("owner"), "contact": .string("c-1")]), .object(["type": .string("admin"), "contact": .string("c-2")])]))
        #expect(await transport.requests.first?.method == "domain/domainsFind")
    }

    @Test func getDomainFiltersByName() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("domains-find")])
        let domain = try await adapter.getDomain(fqdn: "Example.COM.")
        #expect(domain?.fqdn == "example.com")
        let req = try #require(await transport.requests.first)
        #expect(req.param("filter") == HostingDeFilter.or([.equal("DomainName", "example.com"), .equal("DomainNameUnicode", "example.com")]).json)
        #expect(req.param("limit") == .int(1))
    }

    @Test func domainWritesAreUnsupported() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([])
        await #expect(throws: KastellanError.self) { try await adapter.createDomain(fqdn: "x.example", path: nil, extra: [:]) }
        await #expect(throws: KastellanError.self) { try await adapter.deleteDomain(fqdn: "x.example") }
        #expect(!HostingDeAdapter.capabilityMatrix.supports(Capability(.domain, .create)))
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.domain, .get)))
    }

    @Test func listSubdomainsSkipsApexVHostsAndReadsRedirect() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("vhosts-find")])
        let subs = try await adapter.listSubdomains(parent: nil)
        #expect(subs.map(\.fqdn) == ["alt.example.com", "app.example.com"])
        #expect(subs[1].parent == "example.com")
        #expect(subs[1].targetPath == "html/app")
        #expect(subs[1].redirect == nil)
        #expect(subs[0].redirect == "https://example.com/")
        #expect(subs[0].ref.providerRef == "vh-3")
        #expect(subs[0].extra["serverType"] == .string("apache"))
        #expect(await transport.requests.first?.param("filter") == nil)
    }

    @Test func listSubdomainsWithParentUsesWildcardFilter() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("vhosts-find")])
        _ = try await adapter.listSubdomains(parent: "example.com")
        let req = try #require(await transport.requests.first)
        #expect(req.method == "webhosting/vhostsFind")
        #expect(req.param("filter") == HostingDeFilter.or([.equal("VHostDomainName", "*.example.com"), .equal("VHostDomainNameUnicode", "*.example.com")]).json)
    }

    @Test func createSubdomainPicksSingleWebspaceAndWaits() async throws {
        let (adapter, transport, sleeps) = HostingDeFixtures.adapter([
            try HostingDeFixtures.ok("webspaces-find"),
            try HostingDeFixtures.ok("vhost-create-pending"),
            HostingDeFixtures.page([#"{"id":"vh-9","domainName":"neu.example.com","webspaceId":"ws-1","webRoot":"neu","status":"active","locations":[]}"#], page: 1, totalPages: 1),
        ])
        let sub = try await adapter.createSubdomain(fqdn: "Neu.example.com", targetPath: "/html/neu/", redirect: nil, extra: [:])
        #expect(sub.fqdn == "neu.example.com")
        #expect(sub.parent == "example.com")
        #expect(sub.targetPath == "html/neu")
        #expect(sub.ref.providerRef == "vh-9")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["webhosting/webspacesFind", "webhosting/vhostCreate", "webhosting/vhostsFind"])
        let vhost = try #require(requests[1].param("vhost"))
        #expect(vhost.string("webspaceId") == "ws-1")
        #expect(vhost.string("domainName") == "neu.example.com")
        #expect(vhost.string("webRoot") == "neu")
        #expect(vhost.string("serverType") == "nginx")
        #expect(vhost.array("locations").count == 1)
        #expect(requests[2].param("filter") == HostingDeFilter.equal("VHostId", "vh-9").json)
        #expect(await sleeps.seconds == [])
    }

    @Test func createSubdomainWithRedirectAndExplicitWebspace() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            HostingDeFixtures.json(#"{"status":"success","errors":[],"warnings":[],"metadata":{},"response":{"id":"vh-10","domainName":"go.example.com","webspaceId":"ws-2","webRoot":"go.example.com","status":"active","locations":[{"locationType":"redirect","matchType":"directory","matchString":"/","redirectionUrl":"https://example.org/","redirectionStatus":"301"}]}}"#),
        ])
        let sub = try await adapter.createSubdomain(fqdn: "go.example.com", targetPath: nil, redirect: "https://example.org/", extra: ["webspace_id": .string("ws-2"), "php_version": .string("8.3")])
        #expect(sub.redirect == "https://example.org/")
        let vhost = try #require(await transport.requests.first?.param("vhost"))
        #expect(vhost.string("webspaceId") == "ws-2")
        #expect(vhost.string("phpVersion") == "8.3")
        #expect(vhost.string("webRoot") == "go.example.com")
        let locations = vhost.array("locations")
        #expect(locations.count == 2)
        #expect(locations[1].string("locationType") == "redirect")
        #expect(locations[1].string("redirectionUrl") == "https://example.org/")
    }

    @Test func createSubdomainWithSeveralWebspacesNeedsChoice() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([
            HostingDeFixtures.page([#"{"id":"ws-1","name":"Eins"}"#, #"{"id":"ws-2","name":"Zwei"}"#], page: 1, totalPages: 1),
        ])
        await #expect(throws: KastellanError.invalidArgument("hosting.de: mehrere Webspaces, extra.webspace_id angeben: Eins (ws-1), Zwei (ws-2)")) {
            try await adapter.createSubdomain(fqdn: "x.example.com", targetPath: nil, redirect: nil, extra: [:])
        }
    }

    @Test func updateSubdomainSendsWholeVHostWithoutReadOnlyFields() async throws {
        let full = #"{"id":"vh-2","accountId":"acc-42","webspaceId":"ws-1","domainName":"app.example.com","enableAlias":false,"serverType":"nginx","phpVersion":"8.3","webRoot":"app","status":"active","addDate":"2026-02-01T00:00:00Z","lastChangeDate":"2026-02-01T00:00:00Z","systemAlias":"vh-2.wh.hosting.zone","sslSettings":null,"locations":[{"locationType":"generic","matchType":"default","matchString":"","phpEnabled":true,"directoryListingEnabled":false}]}"#
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            HostingDeFixtures.page([full], page: 1, totalPages: 1),
            HostingDeFixtures.json(#"{"status":"success","errors":[],"warnings":[],"metadata":{},"response":{"id":"vh-2","domainName":"app.example.com","webspaceId":"ws-1","webRoot":"app2","status":"active","locations":[{"locationType":"generic","matchType":"default"},{"locationType":"redirect","matchType":"directory","matchString":"/","redirectionUrl":"https://example.net/","redirectionStatus":"301"}]}}"#),
        ])
        let sub = try await adapter.updateSubdomain(fqdn: "app.example.com", targetPath: "app2", redirect: "https://example.net/", extra: [:])
        #expect(sub.targetPath == "html/app2")
        #expect(sub.redirect == "https://example.net/")
        let requests = await transport.requests
        #expect(requests[1].method == "webhosting/vhostUpdate")
        let vhost = try #require(requests[1].param("vhost"))
        #expect(vhost.string("id") == "vh-2")
        #expect(vhost.string("webRoot") == "app2")
        #expect(vhost.string("phpVersion") == "8.3")
        #expect(vhost.string("serverType") == "nginx")
        #expect(vhost["addDate"] == nil)
        #expect(vhost["status"] == nil)
        #expect(vhost["systemAlias"] == nil)
        #expect(vhost["sslSettings"] == .null)
        #expect(vhost.array("locations").count == 2)
    }

    @Test func updateSubdomainRemovesRedirectWithEmptyString() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try HostingDeFixtures.ok("vhosts-find"),
            HostingDeFixtures.json(#"{"status":"success","errors":[],"warnings":[],"metadata":{},"response":{"id":"vh-1","domainName":"example.com","webRoot":"example.com","status":"active","locations":[]}}"#),
        ])
        _ = try await adapter.updateSubdomain(fqdn: "example.com", targetPath: nil, redirect: "", extra: [:])
        let vhost = try #require(await transport.requests[1].param("vhost"))
        #expect(vhost.array("locations").allSatisfy { $0.string("locationType") != "redirect" })
    }

    @Test func deleteSubdomainLooksUpIdAndCallsDelete() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            HostingDeFixtures.page([#"{"id":"vh-3","domainName":"alt.example.com"}"#], page: 1, totalPages: 1),
            HostingDeFixtures.json(#"{"status":"pending","errors":[],"warnings":[],"metadata":{},"response":null}"#),
        ])
        try await adapter.deleteSubdomain(fqdn: "alt.example.com")
        let requests = await transport.requests
        #expect(requests[0].param("filter") == HostingDeFilter.or([.equal("VHostDomainName", "alt.example.com"), .equal("VHostDomainNameUnicode", "alt.example.com")]).json)
        #expect(requests[1].method == "webhosting/vhostDelete")
        #expect(requests[1].param("vhostId") == .string("vh-3"))
    }

    @Test func deleteUnknownSubdomainIsNotFound() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([HostingDeFixtures.page([], page: 1, totalPages: 0, totalEntries: 0)])
        await #expect(throws: KastellanError.notFound("VHost nix.example.com bei hosting.de")) {
            try await adapter.deleteSubdomain(fqdn: "nix.example.com")
        }
    }

    @Test func webRootHelper() {
        #expect(HostingDeAdapter.webRoot(nil, fqdn: "a.example.com") == "a.example.com")
        #expect(HostingDeAdapter.webRoot("/html/app/", fqdn: "a.example.com") == "app")
        #expect(HostingDeAdapter.webRoot("html/", fqdn: "a.example.com") == "a.example.com")
        #expect(HostingDeAdapter.webRoot("sites/a", fqdn: "a.example.com") == "sites/a")
    }
}

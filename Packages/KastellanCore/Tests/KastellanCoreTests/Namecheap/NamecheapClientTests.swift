import Foundation
import Testing
@testable import KastellanCore

struct NamecheapClientTests {
    @Test func callPostsFormWithAuthAndCommand() async throws {
        let (client, transport, _) = NamecheapClient.stubbed([try NamecheapFixtures.ok("users-getbalances")])
        let response = try await client.call("namecheap.users.getBalances")
        #expect(response.child("UserGetBalancesResult")?["Currency"] == "USD")
        let req = try #require(await transport.requests.first)
        #expect(req.url == NamecheapClient.productionURL)
        #expect(req.method == "POST")
        #expect(req.value("ApiUser") == "apiuser")
        #expect(req.value("ApiKey") == "geheim")
        #expect(req.value("UserName") == "apiuser")
        #expect(req.value("ClientIp") == "192.0.2.1")
        #expect(req.command == "namecheap.users.getBalances")
    }

    @Test func sandboxUsesSandboxEndpoint() async throws {
        let (client, transport, _) = NamecheapClient.stubbed([try NamecheapFixtures.ok("users-getbalances")], sandbox: true)
        _ = try await client.call("namecheap.users.getBalances")
        #expect(await transport.requests.first?.url == NamecheapClient.sandboxURL)
    }

    @Test func formEncodingKeepsSpecialCharacters() async throws {
        let (client, transport, _) = NamecheapClient.stubbed([NamecheapFixtures.response("x", "")])
        _ = try await client.call("x", [("Address1", "v=spf1 include:_spf.example.com ~all"), ("Plus", "a+b&c=d")])
        let req = try #require(await transport.requests.first)
        #expect(req.value("Address1") == "v=spf1 include:_spf.example.com ~all")
        #expect(req.value("Plus") == "a+b&c=d")
    }

    @Test func errorsMapToKastellanErrors() async throws {
        let (client, _, _) = NamecheapClient.stubbed([
            NamecheapFixtures.error("1011102", "API Key is invalid or API access has not been enabled"),
            NamecheapFixtures.error("1011150", "Parameter RequestIP is invalid"),
            NamecheapFixtures.error("1011105", "Parameter ClientIP is invalid"),
            try NamecheapFixtures.ok("domains-dns-gethosts-example13-com"),
            try NamecheapFixtures.ok("domains-getregistrarlock-example33-com").withRegistrarLockError(),
            NamecheapFixtures.error("2019166", "Domain not found"),
            NamecheapFixtures.error("3031510", "Something else"),
            NamecheapResponse(status: 502, body: Data()),
        ])
        await #expect { try await client.call("a") } throws: { ($0 as? KastellanError).map { if case .unauthorized(let m) = $0 { m.contains("API-Key ungültig") } else { false } } ?? false }
        await #expect { try await client.call("a") } throws: { ($0 as? KastellanError).map { if case .unauthorized(let m) = $0 { m.contains("IP ist nicht freigegeben") } else { false } } ?? false }
        await #expect { try await client.call("a") } throws: { ($0 as? KastellanError).map { if case .invalidArgument(let m) = $0 { m.contains("Client-IP") } else { false } } ?? false }
        await #expect { try await client.call("a") } throws: { ($0 as? KastellanError).map { if case .unsupported(let m) = $0 { m.contains("Namecheap-Nameserver") && m.contains("2030288") } else { false } } ?? false }
        await #expect { try await client.call("a") } throws: { ($0 as? KastellanError).map { if case .unsupported(let m) = $0 { m.contains("Registrar-Lock") } else { false } } ?? false }
        await #expect { try await client.call("a") } throws: { ($0 as? KastellanError).map { if case .notFound = $0 { true } else { false } } ?? false }
        await #expect(throws: KastellanError.provider("Namecheap a: Something else (3031510)")) { try await client.call("a") }
        await #expect(throws: KastellanError.provider("Namecheap a: HTTP 502")) { try await client.call("a") }
    }

    @Test func listFollowsPaging() async throws {
        let page1 = (0..<100).map { #"<Domain ID="\#($0)" Name="d\#($0).example.com" />"# }.joined()
        let page2 = (100..<130).map { #"<Domain ID="\#($0)" Name="d\#($0).example.com" />"# }.joined()
        let (client, transport, _) = NamecheapClient.stubbed([
            NamecheapFixtures.response("namecheap.domains.getList", "<DomainGetListResult>\(page1)</DomainGetListResult><Paging><TotalItems>130</TotalItems><CurrentPage>1</CurrentPage><PageSize>100</PageSize></Paging>"),
            NamecheapFixtures.response("namecheap.domains.getList", "<DomainGetListResult>\(page2)</DomainGetListResult><Paging><TotalItems>130</TotalItems><CurrentPage>2</CurrentPage><PageSize>100</PageSize></Paging>"),
        ])
        let items = try await client.list("namecheap.domains.getList", item: "Domain")
        #expect(items.count == 130)
        let requests = await transport.requests
        #expect(requests.map { $0.value("Page") } == ["1", "2"])
        #expect(requests.allSatisfy { $0.value("PageSize") == "100" })
    }

    @Test func realDomainListFixtureParses() async throws {
        let (client, _, _) = NamecheapClient.stubbed([try NamecheapFixtures.ok("domains-getlist")])
        let items = try await client.list("namecheap.domains.getList", item: "Domain")
        #expect(items.count == 33)
        #expect(items.filter { $0.bool("IsOurDNS") == false }.count == 2)
    }

    @Test func throttleWaitsWhenMinuteLimitIsReached() async throws {
        let clock = NamecheapFakeClock()
        let responses = (0..<51).map { _ in NamecheapFixtures.response("x", "") }
        let (client, transport, sleeps) = NamecheapClient.stubbed(responses, clock: clock)
        for _ in 0..<50 { _ = try await client.call("x"); clock.advance(by: 0.1) }
        #expect(await sleeps.seconds.isEmpty)
        _ = try await client.call("x")
        #expect(await transport.requests.count == 51)
        let waited = await sleeps.seconds.reduce(0, +)
        #expect(waited > 54 && waited <= 60)
    }

    @Test func splitDomain() throws {
        #expect(try NamecheapClient.split("Example.com") == ("example", "com"))
        #expect(try NamecheapClient.split("example.co.uk.") == ("example", "co.uk"))
        #expect(throws: KastellanError.self) { try NamecheapClient.split("localhost") }
    }

    @Test func xmlParserKeepsAttributesAndText() throws {
        let root = try NamecheapXMLElement.parse(try NamecheapFixtures.data("domains-dns-getlist-example33-com"))
        #expect(root.name == "ApiResponse")
        let result = try #require(root.firstDescendant("DomainDNSGetListResult"))
        #expect(result.bool("IsUsingOurDNS") == true)
        #expect(result.children("Nameserver").map(\.text) == ["dns1.registrar-servers.com", "dns2.registrar-servers.com"])
    }
}

struct NamecheapAdapterTests {
    @Test func registeredWithSettingsAndSecrets() {
        let entry = BuiltinAdapters.registry.entry(for: "namecheap")
        #expect(entry?.displayName == "Namecheap")
        #expect(entry?.secretKeys.map(\.key) == ["api_key"])
        #expect(entry?.settingKeys.map(\.key) == ["api_user", "username", "client_ip", "sandbox"])
    }

    @Test func healthCheckCountsDomains() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([try NamecheapFixtures.ok("domains-getlist-foreign-client-ip-page1")])
        let health = await adapter.healthCheck()
        #expect(health.ok)
        #expect(health.message == "ok, 33 Domains")
        #expect(await transport.requests.first?.value("PageSize") == "10")
    }

    @Test func healthCheckExplainsIPWhitelist() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([NamecheapFixtures.error("1011150", "Parameter RequestIP is invalid")])
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message.contains("Namecheap API Access"))
    }

    @Test func missingSettingsAreReported() async throws {
        struct NoSecrets: SecretProvider { func secret(connectionID: String, key: String) async throws -> String? { "k" } }
        let adapter = NamecheapAdapter(connection: NamecheapFixtures.connection(settings: ["api_user": "u"]), secrets: NoSecrets())
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message.contains("Client-IP fehlt"))
    }

    @Test func sandboxSetting() {
        #expect(NamecheapAdapter.isSandbox("ja"))
        #expect(NamecheapAdapter.isSandbox("true"))
        #expect(!NamecheapAdapter.isSandbox(""))
        #expect(!NamecheapAdapter.isSandbox(nil))
    }

    @Test func dates() {
        #expect(NamecheapAdapter.isoDay("06/01/2027") == .string("2027-06-01"))
        #expect(NamecheapAdapter.date("") == nil)
    }
}

extension NamecheapResponse {
    /// Die gespeicherte Lock-Fixture ist ein Erfolg; für den Fehlerfall den `.de`-Fehler einsetzen.
    func withRegistrarLockError() -> NamecheapResponse {
        NamecheapFixtures.error("2015280", ".DE domains does not support to change Registrar Lock.")
    }
}

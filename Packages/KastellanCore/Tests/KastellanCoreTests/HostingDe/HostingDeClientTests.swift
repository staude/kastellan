import Foundation
import Testing
@testable import KastellanCore

struct HostingDeClientTests {
    @Test func postCarriesTokenMethodURLAndOwnerAccount() async throws {
        let (client, transport, _) = HostingDeClient.stubbed([try HostingDeFixtures.ok("zoneconfigs-find")], token: "key-123", ownerAccountID: "acc-42")
        let r = try await client.call("dns", "zoneConfigsFind", ["limit": .int(1)])
        #expect(r.pending == false)
        #expect(r.response.array("data").count == 2)
        let req = try #require(await transport.requests.first)
        #expect(req.url.absoluteString == "https://secure.hosting.de/api/dns/v1/json/zoneConfigsFind")
        #expect(req.method == "dns/zoneConfigsFind")
        #expect(req.param("authToken") == .string("key-123"))
        #expect(req.param("ownerAccountId") == .string("acc-42"))
        #expect(req.param("limit") == .int(1))
    }

    @Test func ownerAccountIsOmittedWhenEmpty() async throws {
        let (client, transport, _) = HostingDeClient.stubbed([try HostingDeFixtures.ok("zoneconfigs-find")], ownerAccountID: "")
        try await client.call("dns", "zoneConfigsFind")
        let req = try #require(await transport.requests.first)
        #expect(req.param("ownerAccountId") == nil)
    }

    @Test func pendingResponseKeepsPayloadAndWarnings() async throws {
        let (client, _, _) = HostingDeClient.stubbed([try HostingDeFixtures.ok("zone-update-pending")])
        let r = try await client.call("dns", "zoneUpdate")
        #expect(r.pending)
        #expect(r.response["zoneConfig"]?.string("status") == "blocked")
        #expect(r.response.array("records").count == 2)
        #expect(r.warnings == ["33001: TTL raised to minimum of 60 seconds (/recordsToAdd/0/ttl)"])
        #expect(await client.lastWarnings == r.warnings)
    }

    @Test func errorsMapToKastellanErrors() async throws {
        let (client, _, _) = HostingDeClient.stubbed([
            try HostingDeFixtures.ok("error-auth"),
            try HostingDeFixtures.ok("error-validation"),
            HostingDeFixtures.json(#"{"status":"error","errors":[{"code":40004,"text":"Zone not found","contextPath":""}],"warnings":[]}"#),
            HostingDeFixtures.json("<html>maintenance</html>", status: 503),
            HostingDeFixtures.json("{}", status: 500),
        ])
        await #expect(throws: KastellanError.unauthorized("zoneConfigsFind: 10001: The authToken is invalid or has expired.")) {
            try await client.call("dns", "zoneConfigsFind")
        }
        await #expect(throws: KastellanError.provider("zoneUpdate: 32002: TTL must be at least 60 seconds (/recordsToAdd/0/ttl)")) {
            try await client.call("dns", "zoneUpdate")
        }
        await #expect(throws: KastellanError.notFound("zonesFind: 40004: Zone not found")) {
            try await client.call("dns", "zonesFind")
        }
        await #expect(throws: KastellanError.provider("hosting.de: Antwort ist kein JSON (dns/zonesFind, HTTP 503)")) {
            try await client.call("dns", "zonesFind")
        }
        await #expect(throws: KastellanError.provider("zonesFind: HTTP 500")) {
            try await client.call("dns", "zonesFind")
        }
    }

    @Test func findAllWalksPagesAndSendsFilter() async throws {
        let (client, transport, _) = HostingDeClient.stubbed([
            HostingDeFixtures.page([#"{"id":"a"}"#, #"{"id":"b"}"#], page: 1, totalPages: 3, totalEntries: 5),
            HostingDeFixtures.page([#"{"id":"c"}"#, #"{"id":"d"}"#], page: 2, totalPages: 3, totalEntries: 5),
            HostingDeFixtures.page([#"{"id":"e"}"#], page: 3, totalPages: 3, totalEntries: 5),
        ])
        let filter = HostingDeFilter.and([.equal("ZoneName", "example.com"), .unequal("RecordType", "SOA")])
        let items = try await client.findAll("dns", "recordsFind", filter: filter, sort: ("RecordName", false))
        #expect(items.compactMap { $0.string("id") } == ["a", "b", "c", "d", "e"])
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.map { $0.param("page") } == [.int(1), .int(2), .int(3)])
        #expect(requests[0].param("filter") == .object([
            "subFilterConnective": .string("AND"),
            "subFilter": .array([
                .object(["field": .string("ZoneName"), "value": .string("example.com")]),
                .object(["field": .string("RecordType"), "value": .string("SOA"), "relation": .string("unequal")]),
            ]),
        ]))
        #expect(requests[0].param("sort") == .object(["field": .string("RecordName"), "order": .string("ASC")]))
    }

    @Test func findPageReportsTotal() async throws {
        let (client, _, _) = HostingDeClient.stubbed([HostingDeFixtures.page([#"{"id":"a"}"#], page: 1, totalPages: 9, totalEntries: 812)])
        let (data, total) = try await client.findPage("dns", "zoneConfigsFind", limit: 1)
        #expect(data.count == 1)
        #expect(total == 812)
    }

    @Test func waitUntilActiveBacksOffUntilActive() async throws {
        let (client, _, sleeps) = HostingDeClient.stubbed([
            HostingDeFixtures.object(status: "blocked"),
            HostingDeFixtures.object(status: "blocked"),
            HostingDeFixtures.object(status: "blocked"),
            HostingDeFixtures.object(status: "blocked"),
            HostingDeFixtures.object(status: "active"),
        ])
        let result = try await client.waitUntilActive("Zone example.com") {
            try await client.response("dns", "zoneConfigsFind")
        }
        #expect(result.string("status") == "active")
        #expect(await sleeps.seconds == [1, 2, 4, 8])
    }

    @Test func waitUntilActiveTimesOutWithHint() async throws {
        let (client, transport, _) = HostingDeClient.stubbed([], pollTimeout: .seconds(20))
        for _ in 0..<10 { await transport.enqueue(HostingDeFixtures.object(status: "creating")) }
        await #expect(throws: KastellanError.provider("hosting.de: Postfach nach 20 s noch im Zustand creating; der Vorgang läuft bei hosting.de weiter")) {
            try await client.waitUntilActive("Postfach") { try await client.response("email", "mailboxesFind") }
        }
    }

    @Test func waitUntilActiveFailsOnFailedState() async throws {
        let (client, _, _) = HostingDeClient.stubbed([HostingDeFixtures.object(status: "failed")])
        await #expect(throws: KastellanError.provider("hosting.de: Zone ist in den Zustand failed gelaufen")) {
            try await client.waitUntilActive("Zone") { try await client.response("dns", "zonesFind") }
        }
    }

    @Test func serializesConcurrentCalls() async throws {
        let (client, transport, _) = HostingDeClient.stubbed([
            try HostingDeFixtures.ok("zoneconfigs-find"), try HostingDeFixtures.ok("zoneconfigs-find"), try HostingDeFixtures.ok("zoneconfigs-find"),
        ])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { try await client.call("dns", "zoneConfigsFind") } }
            try await group.waitForAll()
        }
        #expect(await transport.requests.count == 3)
    }
}

struct HostingDeAdapterTests {
    @Test func registeredWithSettingsAndSecrets() {
        let entry = BuiltinAdapters.registry.entry(for: "hostingde")
        #expect(entry?.displayName == "hosting.de")
        #expect(entry?.secretKeys.map(\.key) == ["api_key"])
        #expect(entry?.settingKeys.map(\.key) == ["account_id", "base_url", "mailbox_product"])
    }

    @Test func healthCheckCountsZones() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([HostingDeFixtures.page([#"{"id":"zc-1"}"#], page: 1, totalPages: 3, totalEntries: 3)], settings: ["account_id": "acc-42"])
        let health = await adapter.healthCheck()
        #expect(health.ok)
        #expect(health.message == "ok, 3 DNS-Zonen, Unterkonto acc-42")
        let req = try #require(await transport.requests.first)
        #expect(req.method == "dns/zoneConfigsFind")
        #expect(req.param("limit") == .int(1))
        #expect(req.param("ownerAccountId") == .string("acc-42"))
    }

    @Test func healthCheckReportsRejectedKey() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("error-auth")])
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message.hasPrefix("API-Key abgelehnt"))
    }

    @Test func baseURLSettingSwitchesPlatform() async throws {
        struct NoSecrets: SecretProvider {
            func secret(connectionID: String, key: String) async throws -> String? { "k" }
        }
        let adapter = HostingDeAdapter(connection: HostingDeFixtures.connection(settings: ["base_url": "https://partner.http.net/api"]), secrets: NoSecrets())
        #expect(adapter.connection.settings["base_url"] == "https://partner.http.net/api")
    }
}

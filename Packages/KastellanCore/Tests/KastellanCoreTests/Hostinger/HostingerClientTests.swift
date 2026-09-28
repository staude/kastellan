import Foundation
import Testing
@testable import KastellanCore

struct HostingerClientTests {
    @Test func getCarriesBearerTokenAndBaseURL() async throws {
        let (client, transport, _) = HostingerClient.stubbed([try HostingerFixtures.ok("portfolio")], token: "tok-1")
        let json = try await client.get("/api/domains/v1/portfolio")
        #expect(json.arrayValue?.count == 2)
        let req = try #require(await transport.requests.first)
        #expect(req.url.absoluteString == "https://developers.hostinger.com/api/domains/v1/portfolio")
        #expect(req.headers["Authorization"] == "Bearer tok-1")
        #expect(req.headers["Content-Type"] == "application/json")
        #expect(await client.rateLimitRemaining == 89)
    }

    @Test func listReadsBareArrayAndEnvelopePages() async throws {
        let (client, transport, _) = HostingerClient.stubbed([
            try HostingerFixtures.ok("portfolio"),
            HostingerFixtures.page((0..<100).map { #"{"id":\#($0)}"# }, page: 1, perPage: 100, total: 130),
            HostingerFixtures.page((100..<130).map { #"{"id":\#($0)}"# }, page: 2, perPage: 100, total: 130),
        ])
        let bare = try await client.list("/api/domains/v1/portfolio")
        #expect(bare.count == 2)
        let paged = try await client.list("/api/vps/v1/public-keys")
        #expect(paged.count == 130)
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[1].query == ["page": "1", "per_page": "100"])
        #expect(requests[2].query["page"] == "2")
    }

    @Test func errorsMapToKastellanErrors() async throws {
        let (client, _, _) = HostingerClient.stubbed([
            HostingerFixtures.json(#"{"message":"Validation failed","errors":{"zone.0.ttl":["must be at least 60"]},"correlation_id":"c-1"}"#, status: 422),
            HostingerFixtures.json(#"{"message":"Unauthenticated.","correlation_id":"c-2"}"#, status: 401),
            HostingerFixtures.json(#"{"error":"Not found"}"#, status: 404),
            HostingerFixtures.json("<html>", status: 502),
        ])
        await #expect(throws: KastellanError.invalidArgument("PUT /x: Validation failed (zone.0.ttl: must be at least 60; correlation_id c-1)")) { try await client.put("/x", body: .object([:])) }
        await #expect(throws: KastellanError.unauthorized("Unauthenticated. (correlation_id c-2)")) { try await client.get("/x") }
        await #expect(throws: KastellanError.notFound("GET /x: Not found")) { try await client.get("/x") }
        await #expect(throws: KastellanError.provider("GET /x: HTTP 502")) { try await client.get("/x") }
    }

    @Test func rateLimitWaitsRetryAfterOnce() async throws {
        let (client, transport, sleeps) = HostingerClient.stubbed([
            HostingerFixtures.json(#"{"message":"Too Many Attempts."}"#, status: 429, headers: ["Retry-After": "7"]),
            try HostingerFixtures.ok("portfolio"),
        ])
        _ = try await client.get("/api/domains/v1/portfolio")
        #expect(await transport.requests.count == 2)
        #expect(await sleeps.seconds == [7])
    }

    @Test func waitForActionPollsUntilSuccessOrError() async throws {
        let (client, transport, sleeps) = HostingerClient.stubbed([
            HostingerFixtures.action(id: 5, state: "sent"), HostingerFixtures.action(id: 5, state: "success"),
        ])
        let start = try JSONCoding.decoder.decode(JSONValue.self, from: HostingerFixtures.action(id: 5, state: "created").body)
        let done = try await client.waitForAction(start, vm: "42")
        #expect(done.string("state") == "success")
        #expect(await transport.requests.map(\.path) == ["/api/vps/v1/virtual-machines/42/actions/5", "/api/vps/v1/virtual-machines/42/actions/5"])
        #expect(await sleeps.seconds == [2, 2])
        let failed = try JSONCoding.decoder.decode(JSONValue.self, from: HostingerFixtures.action(id: 6, name: "stop", state: "error").body)
        await #expect(throws: KastellanError.provider("Hostinger: Aktion stop auf Server 42 fehlgeschlagen")) { try await client.waitForAction(failed, vm: "42") }
    }

    @Test func emptyBodyIsNull() async throws {
        let (client, _, _) = HostingerClient.stubbed([HostingerResponse(status: 204)])
        #expect(try await client.delete("/x") == .null)
    }
}

struct HostingerAdapterTests {
    @Test func registeredWithSettingsAndSecrets() {
        let entry = BuiltinAdapters.registry.entry(for: "hostinger")
        #expect(entry?.displayName == "Hostinger")
        #expect(entry?.secretKeys.map(\.key) == ["api_token"])
        #expect(entry?.settingKeys.map(\.key) == ["website", "mail_host"])
    }

    @Test func healthCheckCountsDomainsAndSubscriptions() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            try HostingerFixtures.ok("portfolio"),
            HostingerFixtures.json(#"[{"id":"s-1","name":"Premium","status":"active"},{"id":"s-2","name":"VPS","status":"cancelled"}]"#),
        ])
        let health = await adapter.healthCheck()
        #expect(health.ok)
        #expect(health.message == "ok, 2 Domains, 1 aktive Abonnements, Rate-Limit 89 übrig")
        #expect(await transport.requests[0].path == "/api/domains/v1/portfolio")
    }

    @Test func healthCheckReportsRejectedToken() async throws {
        let (adapter, _, _) = HostingerFixtures.adapter([HostingerFixtures.json(#"{"message":"Unauthenticated.","correlation_id":"c"}"#, status: 401)])
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message.hasPrefix("API-Token abgelehnt"))
    }

    @Test func dateParsing() {
        #expect(HostingerDates.date("2026-09-10T08:00:00Z") != nil)
        #expect(HostingerDates.date("2026-09-10 08:00:00") != nil)
        #expect(HostingerDates.date("") == nil)
    }
}

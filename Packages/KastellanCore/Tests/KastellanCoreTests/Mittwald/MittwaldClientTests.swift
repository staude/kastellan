import Foundation
import Testing
@testable import KastellanCore

struct MittwaldClientTests {
    @Test func getCarriesBearerTokenAndBaseURL() async throws {
        let (client, transport, _) = MittwaldClient.stubbed([try MittwaldFixtures.ok("projects")], token: "tok-1")
        let json = try await client.get("/projects", query: [("customerId", "c-1")])
        #expect(json.arrayValue?.count == 2)
        let req = try #require(await transport.requests.first)
        #expect(req.method == "GET")
        #expect(req.url.absoluteString == "https://api.mittwald.de/v2/projects?customerId=c-1")
        #expect(req.headers["Authorization"] == "Bearer tok-1")
        #expect(req.headers["if-event-reached"] == nil)
        #expect(await client.rateLimitRemaining == 2999)
    }

    @Test func writeStoresEtagAndReadsSendIfEventReached() async throws {
        let (client, transport, sleeps) = MittwaldClient.stubbed([
            MittwaldFixtures.json(#"{"id":"m-1"}"#, status: 201, headers: ["etag": "42"]),
            MittwaldFixtures.error(412, type: "EventNotReached", message: "event not reached"),
            MittwaldFixtures.json(#"{"id":"m-1","address":"a@example.com"}"#),
        ])
        try await client.post("/projects/p-1/mail-addresses", body: .object(["address": .string("a@example.com")]))
        #expect(await client.lastEventTag == "42")
        let json = try await client.get("/mail-addresses/m-1")
        #expect(json.string("address") == "a@example.com")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[1].headers["if-event-reached"] == "42")
        #expect(requests[2].headers["if-event-reached"] == "42")
        #expect(await sleeps.seconds == [1])
    }

    @Test func errorsMapToKastellanErrors() async throws {
        let (client, _, _) = MittwaldClient.stubbed([
            MittwaldFixtures.json(#"{"type":"ValidationError","message":"Validation failed","validationErrors":[{"type":"minLength","path":"mailbox.password","message":"too short"}]}"#, status: 400),
            MittwaldFixtures.json(#"{"params":{"traceId":"t"},"message":"unauthenticated","type":"Unauthenticated"}"#, status: 401),
            MittwaldFixtures.error(403, type: "PermissionDenied", message: "no"),
            MittwaldFixtures.error(404, type: "NotFound", message: "project not found"),
            MittwaldFixtures.json("<html>", status: 502),
        ])
        await #expect(throws: KastellanError.invalidArgument("POST /x: ValidationError: Validation failed (mailbox.password: too short)")) { try await client.post("/x") }
        await #expect(throws: KastellanError.unauthorized("Unauthenticated: unauthenticated")) { try await client.get("/x") }
        await #expect(throws: KastellanError.unauthorized("PermissionDenied: no")) { try await client.get("/x") }
        await #expect(throws: KastellanError.notFound("GET /projects/p: NotFound: project not found")) { try await client.get("/projects/p") }
        await #expect(throws: KastellanError.provider("GET /x: http_502: HTTP 502")) { try await client.get("/x") }
    }

    @Test func rateLimitWaitsAndRetriesOnce() async throws {
        let (client, transport, sleeps) = MittwaldClient.stubbed([
            MittwaldFixtures.json(#"{"type":"RateLimitError","message":"too many requests"}"#, status: 429, headers: ["X-RateLimit-Reset": "4"]),
            try MittwaldFixtures.ok("projects"),
        ])
        let json = try await client.get("/projects")
        #expect(json.arrayValue?.count == 2)
        #expect(await transport.requests.count == 2)
        #expect(await sleeps.seconds == [4])
    }

    @Test func listWalksPagesByTotalCount() async throws {
        let (client, transport, _) = MittwaldClient.stubbed([
            MittwaldFixtures.page((0..<100).map { #"{"id":"\#($0)"}"# }, total: 150),
            MittwaldFixtures.page((100..<150).map { #"{"id":"\#($0)"}"# }, total: 150),
        ])
        let items = try await client.list("/projects", query: [("customerId", "c-1")])
        #expect(items.count == 150)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].query == ["customerId": "c-1", "limit": "100", "skip": "0"])
        #expect(requests[1].query["skip"] == "100")
    }

    @Test func waitUntilPollsWithBackoffAndTimesOut() async throws {
        let (client, _, sleeps) = MittwaldClient.stubbed([
            MittwaldFixtures.json(#"{"status":"pending"}"#), MittwaldFixtures.json(#"{"status":"pending"}"#), MittwaldFixtures.json(#"{"status":"ready"}"#),
        ])
        let result = try await client.waitUntil("Datenbank") { try await client.get("/x") } ready: { $0.string("status") == "ready" }
        #expect(result.string("status") == "ready")
        #expect(await sleeps.seconds == [1, 2])

        let (slow, transport, _) = MittwaldClient.stubbed([], pollTimeout: .seconds(10))
        for _ in 0..<10 { await transport.enqueue(MittwaldFixtures.json(#"{"status":"pending"}"#)) }
        await #expect(throws: KastellanError.provider("Mittwald: Datenbank nach 10 s noch nicht bereit; der Vorgang läuft bei Mittwald weiter")) {
            try await slow.waitUntil("Datenbank") { try await slow.get("/x") } ready: { $0.string("status") == "ready" }
        }
    }

    @Test func emptyBodyIsNull() async throws {
        let (client, _, _) = MittwaldClient.stubbed([MittwaldFixtures.empty()])
        #expect(try await client.delete("/mail-addresses/m-1") == .null)
    }
}

struct MittwaldAdapterTests {
    static let session = #"{"userId":"u-1","tokenId":"t-1","isEmployee":false,"isImpersonated":false}"#
    static func tokens(expires: String?) -> String {
        let e = expires.map { #","expiresAt":"\#($0)""# } ?? ""
        return #"[{"apiTokenId":"t-1","description":"Kastellan","roles":["api_read","api_write"],"createdAt":"2026-09-01T00:00:00Z"\#(e)}]"#
    }

    @Test func registeredWithSettingsAndSecrets() {
        let entry = BuiltinAdapters.registry.entry(for: "mittwald")
        #expect(entry?.displayName == "Mittwald")
        #expect(entry?.secretKeys.map(\.key) == ["api_token"])
        #expect(entry?.settingKeys.map(\.key) == ["project_id", "customer_id", "mail_host"])
    }

    @Test func healthCheckReportsProjectsRolesAndExpiry() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.json(Self.session),
            try MittwaldFixtures.ok("projects", headers: ["X-Pagination-TotalCount": "2"]),
            MittwaldFixtures.page([Self.tokens(expires: "2027-09-01T00:00:00Z").dropFirst().dropLast().description], total: 1),
        ], settings: ["customer_id": "c-1"])
        let health = await adapter.healthCheck()
        #expect(health.ok)
        #expect(health.message == "ok, 2 Projekte, Rollen api_read, api_write, Token gültig bis 2027-09-01")
        let requests = await transport.requests
        #expect(requests[0].path == "/users/self/sessions/current/status")
        #expect(requests[1].path == "/projects")
        #expect(requests[1].query["customerId"] == "c-1")
        #expect(requests[2].path == "/users/self/api-tokens")
    }

    @Test func healthCheckWarnsBeforeExpiryAndFailsAfter() async throws {
        let soon = MittwaldDates.string(Date().addingTimeInterval(10 * 86400))
        let (adapter, _, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.json(Self.session), MittwaldFixtures.page([], total: 0),
            MittwaldFixtures.page([Self.tokens(expires: soon).dropFirst().dropLast().description], total: 1),
        ])
        let health = await adapter.healthCheck()
        #expect(health.ok)
        #expect(health.message.contains("Token läuft in 9 Tagen ab") || health.message.contains("Token läuft in 10 Tagen ab"))

        let (expired, _, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.json(Self.session), MittwaldFixtures.page([], total: 0),
            MittwaldFixtures.page([Self.tokens(expires: "2026-01-01T00:00:00Z").dropFirst().dropLast().description], total: 1),
        ])
        let h2 = await expired.healthCheck()
        #expect(!h2.ok)
        #expect(h2.message == "API-Token ist am 2026-01-01 abgelaufen")
    }

    @Test func healthCheckReportsRejectedToken() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([MittwaldFixtures.json(#"{"type":"Unauthenticated","message":"unauthenticated"}"#, status: 401)])
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message.hasPrefix("API-Token abgelehnt"))
    }

    @Test func projectResolutionPrefersExtraThenSettingThenSingle() async throws {
        let (fixed, _, _) = MittwaldFixtures.adapter([], settings: ["project_id": "p-set"])
        #expect(try await fixed.projectID() == "p-set")
        #expect(try await fixed.projectID(["project_id": .string("p-extra")]) == "p-extra")
        #expect(try await fixed.projectIDs() == ["p-set"])

        let (multi, _, _) = MittwaldFixtures.adapter([try MittwaldFixtures.ok("projects"), try MittwaldFixtures.ok("projects")])
        #expect(try await multi.projectIDs() == ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"])
        await #expect(throws: KastellanError.invalidArgument("Mittwald: mehrere Projekte, extra.project_id oder Verbindungs-Einstellung Projekt-ID angeben: Website (p-aaaaa1), Shop (p-bbbbb2)")) {
            try await multi.projectID()
        }
        let (single, _, _) = MittwaldFixtures.adapter([MittwaldFixtures.page([#"{"id":"only","description":"Eins","shortId":"p-1"}"#], total: 1)])
        #expect(try await single.projectID() == "only")
    }
}

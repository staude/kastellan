import Foundation
import Testing
@testable import KastellanCore

struct HetznerClientTests {
    @Test func requestCarriesBearerTokenAndBaseURL() async throws {
        let (client, transport, _) = HetznerClient.stubbed([try HetznerFixtures.ok("zones")], token: "tok-123")
        let json = try await client.get("/zones", query: [("name", "example.com")])
        #expect(json.array("zones").count == 2)
        let req = try #require(await transport.requests.first)
        #expect(req.method == "GET")
        #expect(req.url.absoluteString == "https://api.hetzner.cloud/v1/zones?name=example.com")
        #expect(req.authorization == "Bearer tok-123")
        #expect(req.body == nil)
        #expect(await client.rateLimitRemaining == 3599)
    }

    @Test func postEncodesJSONBody() async throws {
        let (client, transport, _) = HetznerClient.stubbed([HetznerFixtures.action(command: "create_rrset")])
        try await client.post("/zones/example.com/rrsets", body: .object(["name": .string("www"), "ttl": .int(300)]))
        let req = try #require(await transport.requests.first)
        #expect(req.method == "POST")
        #expect(req.path == "/zones/example.com/rrsets")
        #expect(req.body == .object(["name": .string("www"), "ttl": .int(300)]))
    }

    @Test func errorEnvelopeMapsToKastellanError() async throws {
        let (client, _, _) = HetznerClient.stubbed([
            HetznerFixtures.error(400, code: "invalid_input", message: "invalid input in field 'name': is too long"),
            try HetznerFixtures.ok("error-unauthorized", status: 401),
            try HetznerFixtures.ok("error-not-found", status: 404),
            HetznerFixtures.json("<html>bad gateway</html>", status: 502),
        ])
        await #expect(throws: KastellanError.provider("invalid_input: invalid input in field 'name': is too long")) {
            try await client.get("/zones")
        }
        await #expect(throws: KastellanError.unauthorized("unauthorized: unable to authenticate")) {
            try await client.get("/zones")
        }
        await #expect(throws: KastellanError.notFound("not_found: rrset not found")) {
            try await client.get("/zones/x/rrsets/www/A")
        }
        await #expect(throws: KastellanError.provider("http_502: HTTP 502")) {
            try await client.get("/zones")
        }
    }

    @Test func nonJSONSuccessBodyIsProviderError() async throws {
        let (client, _, _) = HetznerClient.stubbed([HetznerFixtures.json("not json")])
        await #expect(throws: KastellanError.provider("Hetzner: Antwort ist kein JSON (GET /zones)")) {
            try await client.get("/zones")
        }
    }

    @Test func emptyBodyIsNull() async throws {
        let (client, _, _) = HetznerClient.stubbed([HetznerFixtures.empty()])
        let result = try await client.delete("/ssh_keys/1")
        #expect(result == .null)
    }

    @Test func retriesOnceAfterRateLimit() async throws {
        let (client, transport, sleeps) = HetznerClient.stubbed([])
        let reset = String(Int(await sleeps.clock.now.timeIntervalSince1970) + 3)
        await transport.enqueue(HetznerFixtures.json(#"{"error":{"code":"rate_limit_exceeded","message":"limit of 3600 requests per hour reached"}}"#,
                                                     status: 429, headers: ["RateLimit-Remaining": "0", "RateLimit-Reset": reset]))
        await transport.enqueue(try HetznerFixtures.ok("zones"))
        let json = try await client.get("/zones")
        #expect(json.array("zones").count == 2)
        #expect(await transport.requests.count == 2)
        #expect(await sleeps.seconds == [3])
    }

    @Test func rateLimitWaitIsCappedAndFloored() async throws {
        let (client, transport, sleeps) = HetznerClient.stubbed([])
        let farAway = String(Int(await sleeps.clock.now.timeIntervalSince1970) + 3600)
        await transport.enqueue(HetznerFixtures.json("{}", status: 429, headers: ["RateLimit-Reset": farAway]))
        await transport.enqueue(HetznerFixtures.json("{}"))
        await transport.enqueue(HetznerFixtures.json("{}", status: 429, headers: [:]))
        await transport.enqueue(HetznerFixtures.json("{}"))
        try await client.get("/zones")
        try await client.get("/zones")
        #expect(await sleeps.seconds == [5, 1])
    }

    @Test func secondRateLimitIsAnError() async throws {
        let (client, transport, sleeps) = HetznerClient.stubbed([
            HetznerFixtures.error(429, code: "rate_limit_exceeded", message: "limit reached"),
            HetznerFixtures.error(429, code: "rate_limit_exceeded", message: "limit reached"),
        ])
        await #expect(throws: KastellanError.provider("rate_limit_exceeded: limit reached")) {
            try await client.get("/zones")
        }
        #expect(await transport.requests.count == 2)
        #expect(await sleeps.durations.count == 1)
    }

    @Test func listFollowsPagination() async throws {
        let page1 = #"{"zones":[{"id":1,"name":"a.de"},{"id":2,"name":"b.de"}],"meta":{"pagination":{"page":1,"per_page":50,"previous_page":null,"next_page":2,"last_page":2,"total_entries":3}}}"#
        let page2 = #"{"zones":[{"id":3,"name":"c.de"}],"meta":{"pagination":{"page":2,"per_page":50,"previous_page":1,"next_page":null,"last_page":2,"total_entries":3}}}"#
        let (client, transport, _) = HetznerClient.stubbed([HetznerFixtures.json(page1), HetznerFixtures.json(page2)])
        let zones = try await client.list("/zones", key: "zones", query: [("mode", "primary")])
        #expect(zones.compactMap { $0.string("name") } == ["a.de", "b.de", "c.de"])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].query == ["mode": "primary", "page": "1", "per_page": "50"])
        #expect(requests[1].query == ["mode": "primary", "page": "2", "per_page": "50"])
    }

    @Test func waitForActionPollsUntilSuccess() async throws {
        let (client, transport, sleeps) = HetznerClient.stubbed([
            try HetznerFixtures.ok("action-running"),
            try HetznerFixtures.ok("action-success"),
        ])
        let start = try HetznerFixtures.ok("rrset-create")
        let response = try JSONCoding.decoder.decode(JSONValue.self, from: start.body)
        let done = try await client.waitForAction(response["action"]!)
        #expect(done.string("status") == "success")
        let requests = await transport.requests
        #expect(requests.map(\.path) == ["/actions/1001", "/actions/1001"])
        #expect(await sleeps.seconds == [1, 1])
    }

    @Test func finishedActionNeedsNoPolling() async throws {
        let (client, transport, sleeps) = HetznerClient.stubbed([])
        let done = try await client.waitForAction(.object(["id": .int(7), "status": .string("success")]))
        #expect(done.int("id") == 7)
        #expect(await transport.requests.isEmpty)
        #expect(await sleeps.durations.isEmpty)
    }

    @Test func failedActionIsProviderError() async throws {
        let (client, _, _) = HetznerClient.stubbed([try HetznerFixtures.ok("action-error")])
        await #expect(throws: KastellanError.provider("create_rrset: action_failed: Action failed")) {
            try await client.waitForAction(.object(["id": .int(1001), "command": .string("create_rrset"), "status": .string("running")]))
        }
    }

    @Test func actionPollingTimesOut() async throws {
        let (client, transport, sleeps) = HetznerClient.stubbed([
            try HetznerFixtures.ok("action-running"),
            try HetznerFixtures.ok("action-running"),
            try HetznerFixtures.ok("action-running"),
        ], pollTimeout: .seconds(3))
        await #expect(throws: KastellanError.provider("Hetzner: Action 1001 (create_rrset) nach 3 s nicht abgeschlossen")) {
            try await client.waitForAction(.object(["id": .int(1001), "command": .string("create_rrset"), "status": .string("running")]))
        }
        #expect(await transport.requests.count == 3)
        #expect(await sleeps.durations.count == 3)
    }

    @Test func waitForActionsCoversNextActions() async throws {
        let (client, transport, _) = HetznerClient.stubbed([try HetznerFixtures.ok("action-success")])
        let response: JSONValue = .object([
            "action": .object(["id": .int(1), "status": .string("success")]),
            "next_actions": .array([.object(["id": .int(1001), "command": .string("start_server"), "status": .string("running")])]),
        ])
        try await client.waitForActions(in: response)
        #expect(await transport.requests.map(\.path) == ["/actions/1001"])
    }

    @Test func tokenProviderErrorsSurface() async throws {
        let transport = HetznerStubTransport([])
        let client = HetznerClient(tokenProvider: { throw KastellanError.unauthorized("kein Token") }, transport: transport)
        await #expect(throws: KastellanError.unauthorized("kein Token")) { try await client.get("/zones") }
        #expect(await transport.requests.isEmpty)
    }
}

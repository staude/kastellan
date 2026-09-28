import Foundation
import Testing
@testable import KastellanCore

struct CloudflareClientTests {
    @Test func successEnvelopeReturnsResultAndSendsBearerToken() async throws {
        let (client, transport, _) = CloudflareFixtures.client([try CloudflareFixtures.response("tokens-verify")], token: "geheim-123")
        let info: CloudflareTokenVerification = try await client.get("/user/tokens/verify")
        #expect(info.status == "active")
        #expect(info.expiresOn == "2027-01-01T00:00:00Z")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/user/tokens/verify")
        #expect(request.authorization == "Bearer geheim-123")
        #expect(request.body == nil)
    }

    @Test func failureEnvelopeBecomesProviderError() async throws {
        let (client, _, _) = CloudflareFixtures.client([try CloudflareFixtures.response("error-authentication", status: 403)])
        await #expect(throws: KastellanError.provider("10000: Authentication error")) {
            let _: CloudflareTokenVerification = try await client.get("/user/tokens/verify")
        }
    }

    @Test func multipleErrorsAreJoined() async throws {
        let (client, _, _) = CloudflareFixtures.client([try CloudflareFixtures.response("error-record_not_found", status: 404)])
        await #expect(throws: KastellanError.provider("81044: Record does not exist.; 1004: DNS Validation Error")) {
            let _: CloudflareDeletedObject = try await client.delete("/zones/x/dns_records/y")
        }
    }

    @Test func unreadableErrorBodyReportsHTTPStatus() async throws {
        let (client, _, _) = CloudflareFixtures.client([CloudflareStubResponse(data: Data("<html>Bad Gateway</html>".utf8), status: 502, headers: [:])])
        await #expect(throws: KastellanError.provider("Cloudflare: HTTP 502 bei GET /zones")) {
            let _: [CloudflareZone] = try await client.get("/zones")
        }
    }

    @Test func missingResultOnSuccessIsProviderError() async throws {
        let (client, _, _) = CloudflareFixtures.client([CloudflareFixtures.envelope(.null)])
        await #expect(throws: KastellanError.self) {
            let _: CloudflareZone = try await client.get("/zones/abc")
        }
    }

    @Test func emptyTokenIsUnauthorized() async throws {
        let (client, transport, _) = CloudflareFixtures.client([try CloudflareFixtures.response("tokens-verify")], token: "")
        await #expect(throws: KastellanError.unauthorized("Cloudflare-API-Token ist leer")) {
            let _: CloudflareTokenVerification = try await client.get("/user/tokens/verify")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func listFollowsPagination() async throws {
        let (client, transport, _) = CloudflareFixtures.client([
            try CloudflareFixtures.response("zones-page1"),
            try CloudflareFixtures.response("zones-page2"),
        ])
        let zones: [CloudflareZone] = try await client.list("/zones")
        #expect(zones.map(\.name) == ["example.com", "beispiel-zone.de", "beispiel-shop.com"])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].query == ["page": "1", "per_page": "100"])
        #expect(requests[1].query == ["page": "2", "per_page": "100"])
    }

    @Test func listKeepsCallerQueryAndStopsOnEmptyPage() async throws {
        let (client, transport, _) = CloudflareFixtures.client([try CloudflareFixtures.response("zones-empty")])
        let zones: [CloudflareZone] = try await client.list("/zones", query: ["name": "nix.de"])
        #expect(zones.isEmpty)
        #expect(await transport.requests.first?.query == ["name": "nix.de", "page": "1", "per_page": "100"])
    }

    @Test func retriesOnceAfter429WithRetryAfter() async throws {
        let (client, transport, sleeps) = CloudflareFixtures.client([
            CloudflareFixtures.empty(status: 429, headers: ["Retry-After": "3"]),
            try CloudflareFixtures.response("tokens-verify"),
        ])
        let info: CloudflareTokenVerification = try await client.get("/user/tokens/verify")
        #expect(info.status == "active")
        #expect(await transport.requests.count == 2)
        #expect(await sleeps.durations == [.seconds(3)])
    }

    @Test func second429IsReportedAsProviderError() async throws {
        let (client, _, sleeps) = CloudflareFixtures.client([
            CloudflareFixtures.empty(status: 429),
            CloudflareFixtures.empty(status: 429),
        ])
        await #expect(throws: KastellanError.provider("Cloudflare: HTTP 429 bei GET /zones")) {
            let _: [CloudflareZone] = try await client.get("/zones")
        }
        #expect(await sleeps.durations == [CloudflareClient.defaultRetryDelay])
    }

    @Test func throttlesAfterRateLimitWithinWindow() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (client, _, sleeps) = CloudflareFixtures.client([
            try CloudflareFixtures.response("tokens-verify"),
            try CloudflareFixtures.response("tokens-verify"),
            try CloudflareFixtures.response("tokens-verify"),
        ], rateLimit: 2, now: { start })
        for _ in 0..<3 {
            let _: CloudflareTokenVerification = try await client.get("/user/tokens/verify")
        }
        // Der dritte Aufruf im selben Fenster wartet, bis der älteste aus dem Fenster fällt (volle 300 s bei stehender Uhr).
        #expect(await sleeps.durations == [.seconds(CloudflareClient.rateWindow)])
    }

    @Test func zoneIDLookupIsCachedAndUnknownZoneIsNotFound() async throws {
        let (client, transport, _) = CloudflareFixtures.client([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("zones-empty"),
        ])
        let first = try await client.zoneID(for: "Example.com.")
        let second = try await client.zoneID(for: "example.com")
        #expect(first == CloudflareFixtures.zoneID)
        #expect(second == first)
        #expect(await transport.requests.count == 1)
        #expect(await transport.requests.first?.query["name"] == "example.com")
        await #expect(throws: KastellanError.notFound("Zone nix.de bei Cloudflare")) {
            try await client.zoneID(for: "nix.de")
        }
    }

    @Test func requestBodyIsEncodedAsJSON() async throws {
        let (client, transport, _) = CloudflareFixtures.client([try CloudflareFixtures.response("dns_record-create")])
        let body: JSONValue = .object(["name": .string("planer.example.com"), "type": .string("A"), "content": .string("203.0.113.10"), "ttl": .int(1)])
        let record: CloudflareDNSRecord = try await client.post("/zones/\(CloudflareFixtures.zoneID)/dns_records", body: body)
        #expect(record.id == "b7c8d9e0f1a2b3c4d5e6f708192a3b4c")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"] == "Bearer cf-test-token")
        #expect(request.json == body)
    }

    @Test func transportBuildsURLWithSortedQuery() {
        let url = URLSessionCloudflareTransport.url(base: URLSessionCloudflareTransport.baseURL, path: "/zones", query: ["per_page": "100", "name": "example.com"])
        #expect(url.absoluteString == "https://api.cloudflare.com/client/v4/zones?name=example.com&per_page=100")
    }
}

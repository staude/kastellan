import Foundation
import Testing
@testable import KastellanCore

struct KASClientTests {
    @Test func sessionFlowAuthenticatesOnceAndReusesToken() async throws {
        let (client, transport, sleeps) = KASClient.stubbed([
            try KASFixtures.response("kasauth"),
            try KASFixtures.response("get_domains"),
            try KASFixtures.response("get_dkim"),
        ])
        #expect(await client.hasSession == false)

        let domains = try await client.call("get_domains")
        #expect(domains.items.count == 2)
        #expect(await client.hasSession)

        let dkim = try await client.call("get_dkim", params: ["host": "example.com"])
        #expect(dkim.items.first?.string("selector") == "kas202609061725")

        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].isAuth)
        #expect(requests[0].soapAction == KASEnvelope.authSOAPAction)
        #expect(requests[0].params["kas_auth_data"] as? String == "geheim")
        #expect(requests[0].params["session_lifetime"] as? Int == 1800)
        #expect(requests[1].url == KASEnvelope.apiURL)
        #expect(requests[1].soapAction == KASEnvelope.apiSOAPAction)
        #expect(requests[1].action == "get_domains")
        #expect(requests[1].params["kas_auth_data"] as? String == "***")
        #expect(requests[1].requestParams.isEmpty)
        #expect(requests[2].action == "get_dkim")
        #expect(requests[2].requestParams == ["host": "example.com"])
        #expect(requests[2].params["kas_auth_data"] as? String == "***")

        // Flood-Delay der ersten Antwort wurde vor dem zweiten Aufruf abgewartet.
        let seconds = await sleeps.seconds
        #expect(seconds.count == 1)
        #expect(seconds.first ?? 0 >= 0.5)
    }

    @Test func floodDelayIsWaitedBeforeEachFollowingCall() async throws {
        let (client, _, sleeps) = KASClient.stubbed([
            try KASFixtures.response("kasauth"),
            KASFixtures.scalarResponse("a", returnInfo: "1", floodDelay: "1.25"),
            KASFixtures.scalarResponse("b", returnInfo: "2", floodDelay: "0"),
            KASFixtures.scalarResponse("c", returnInfo: "3"),
        ])
        _ = try await client.call("a")
        _ = try await client.call("b")
        _ = try await client.call("c")
        let seconds = await sleeps.seconds
        #expect(seconds == [1.25])
    }

    @Test func floodProtectionRetriesOnceAfterTwoSeconds() async throws {
        let (client, transport, sleeps) = KASClient.stubbed([
            try KASFixtures.response("kasauth"),
            KASFixtures.fault("flood_protection"),
            try KASFixtures.response("get_domains"),
        ])
        let response = try await client.call("get_domains")
        #expect(response.items.count == 2)
        #expect(await transport.requests.filter { $0.action == "get_domains" }.count == 2)
        #expect(await sleeps.seconds == [2.0])
    }

    @Test func floodProtectionTwiceGivesUp() async throws {
        let (client, _, sleeps) = KASClient.stubbed([
            try KASFixtures.response("kasauth"),
            KASFixtures.fault("flood_protection"),
            KASFixtures.fault("flood_protection"),
        ])
        await #expect(throws: KASFault.self) {
            try await client.call("get_domains")
        }
        #expect(await sleeps.seconds == [2.0])
    }

    @Test func expiredSessionReauthenticatesOnce() async throws {
        let (client, transport, _) = KASClient.stubbed([
            try KASFixtures.response("kasauth"),
            try KASFixtures.response("get_domains"),
            KASFixtures.fault("session_expired"),
            try KASFixtures.response("kasauth"),
            try KASFixtures.response("get_dkim"),
        ])
        _ = try await client.call("get_domains")
        let dkim = try await client.call("get_dkim", params: ["host": "example.com"])
        #expect(dkim.items.count == 1)
        let requests = await transport.requests
        #expect(requests.map(\.isAuth) == [true, false, false, true, false])
    }

    @Test func faultIsPropagatedWithDetail() async throws {
        let (client, _, _) = KASClient.stubbed([
            try KASFixtures.response("kasauth"),
            try KASFixtures.data("fault-zone_not_found"),
        ])
        let fault = await #expect(throws: KASFault.self) {
            try await client.call("get_dns_settings", params: ["zone_host": "gibt-es-nicht-example.com."])
        }
        #expect(fault?.kastellanError == .provider("zone_not_found: gibt-es-nicht-example.com"))
    }

    @Test func authFailureIsNotRetried() async throws {
        let (client, transport, _) = KASClient.stubbed([
            KASFixtures.fault("auth_failed", detail: "kas_login"),
        ])
        await #expect(throws: KASFault.self) {
            try await client.call("get_domains")
        }
        #expect(await transport.requests.count == 1)
        #expect(await client.hasSession == false)
    }

    @Test func passwordProviderIsAskedLazily() async throws {
        let transport = KASStubTransport([try KASFixtures.response("kasauth"), try KASFixtures.response("get_domains")])
        let secrets = InMemorySecretProvider(["c1/password": "aus-dem-schluesselbund"])
        let client = KASClient(login: "w00abcde", passwordProvider: {
            guard let pw = try await secrets.secret(connectionID: "c1", key: "password") else {
                throw KastellanError.unauthorized("kein Passwort")
            }
            return pw
        }, transport: transport, sleep: { _ in })
        _ = try await client.call("get_domains")
        #expect(await transport.requests.first?.params["kas_auth_data"] as? String == "aus-dem-schluesselbund")
    }

    @Test func callsAreSerialized() async throws {
        var responses = [try KASFixtures.response("kasauth")]
        for i in 0..<10 { responses.append(KASFixtures.scalarResponse("x", returnInfo: "\(i)")) }
        let (client, transport, _) = KASClient.stubbed(responses)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { _ = try await client.call("x", params: ["i": "\(i)"]) }
            }
            try await group.waitForAll()
        }
        // Genau eine Anmeldung, alle zehn Aufrufe kamen an, keiner lief in eine fehlende Antwort.
        let requests = await transport.requests
        #expect(requests.filter(\.isAuth).count == 1)
        #expect(requests.filter { !$0.isAuth }.count == 10)
    }
}

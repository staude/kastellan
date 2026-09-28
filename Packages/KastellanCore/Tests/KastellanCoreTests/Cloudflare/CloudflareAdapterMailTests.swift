import Foundation
import Testing
@testable import KastellanCore

struct CloudflareAdapterMailTests {
    let zoneID = CloudflareFixtures.zoneID
    let account = "a1b2c3d4e5f60718293a4b5c6d7e8f90"

    @Test func capabilityMatrixCoversForwardsAndCertificates() throws {
        let m = CloudflareAdapter.capabilityMatrix
        #expect(m.supports(Capability(.mailForward, .list)))
        #expect(m.supports(Capability(.mailForward, .create)))
        #expect(m.supports(Capability(.mailForward, .update)))
        #expect(m.supports(Capability(.mailForward, .delete)))
        #expect(!m.supports(Capability(.mailForward, .get)))
        #expect(m.supports(Capability(.certificate, .list)))
        #expect(m.supports(Capability(.certificate, .update)))
        #expect(!m.supports(Capability(.certificate, .create)))
        #expect(!m.supports(Capability(.mailbox, .list)))
        #expect(m.resources == [.dnsZone, .dnsRecord, .mailForward, .certificate])

        let conn = Connection(profileID: "privat", provider: "cloudflare", label: "CF")
        let adapter = try BuiltinAdapters.registry.adapter(for: conn, secrets: InMemorySecretProvider())
        #expect(adapter as? any MailForwardAdapter != nil)
        #expect(adapter as? any CertificateAdapter != nil)
        #expect(adapter as? any MailboxAdapter == nil)
    }

    // MARK: - Lesen

    @Test func listForwardsWithoutAccountTakesStatusFromEnabled() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("email_routing-rules"),
            try CloudflareFixtures.response("email_routing-catch_all"),
        ])
        let forwards = try await adapter.listForwards(domain: "example.com")
        #expect(await transport.calls == [
            "GET /zones",
            "GET /zones/\(zoneID)/email/routing/rules",
            "GET /zones/\(zoneID)/email/routing/rules/catch_all",
        ])
        // Die Drop-Regel für spam@ ist keine Weiterleitung.
        #expect(forwards.map(\.address) == ["info@example.com", "alt@example.com", "neu@example.com", "*@example.com"])
        #expect(forwards.map(\.status) == [.active, .disabled, .active, .active])

        let info = forwards[0]
        #expect(info.ref.providerRef == "a7e6fb77503c41d8a7f3113c6c4ea0a6")
        #expect(info.targets == ["user@example.com"])
        #expect(!info.keepCopy)
        #expect(info.extra["rule_id"] == .string("a7e6fb77503c41d8a7f3113c6c4ea0a6"))
        #expect(info.extra["name"] == .string("Info an Max"))
        #expect(info.extra["priority"] == .int(0))
        #expect(info.extra["catch_all"] == .bool(false))
        #expect(info.extra["verification_unknown"] == .bool(true))

        #expect(forwards[1].targets == ["user@example.com", "old@example.net"])
        #expect(forwards[1].extra["enabled"] == .bool(false))

        let catchAll = forwards[3]
        #expect(catchAll.extra["catch_all"] == .bool(true))
        #expect(catchAll.targets == ["user@example.com"])
    }

    @Test func listForwardsWithAccountReportsPendingVerification() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("email_routing-addresses"),
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("email_routing-rules"),
            try CloudflareFixtures.response("email_routing-catch_all"),
        ], accountID: account)
        let forwards = try await adapter.listForwards(domain: "example.com")
        #expect(await transport.calls.first == "GET /accounts/\(account)/email/routing/addresses")
        #expect(forwards.map(\.address) == ["info@example.com", "alt@example.com", "neu@example.com", "*@example.com"])
        // old@example.net ist unbestätigt: neu@ wartet, alt@ bleibt abgeschaltet.
        #expect(forwards.map(\.status) == [.active, .disabled, .pendingVerification, .active])
        #expect(forwards[0].extra["verification_unknown"] == nil)
    }

    @Test func listForwardsWithoutDomainWalksAllZones() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-list"),
            try CloudflareFixtures.response("email_routing-rules"),
            try CloudflareFixtures.response("email_routing-catch_all"),
            CloudflareFixtures.envelope(.array([]), page: 1, totalPages: 1),
            try CloudflareFixtures.response("email_routing-catch_all-disabled"),
        ])
        let forwards = try await adapter.listForwards(domain: nil)
        #expect(forwards.count == 4)
        #expect(forwards.allSatisfy { $0.address.hasSuffix("@example.com") })
        #expect(await transport.calls == [
            "GET /zones",
            "GET /zones/\(zoneID)/email/routing/rules",
            "GET /zones/\(zoneID)/email/routing/rules/catch_all",
            "GET /zones/9a7806061c88ada191ed06f989cc3dac/email/routing/rules",
            "GET /zones/9a7806061c88ada191ed06f989cc3dac/email/routing/rules/catch_all",
        ])
    }

    // MARK: - Anlegen

    @Test func createForwardWithoutAccountIDIsInvalidArgument() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([])
        await #expect(throws: KastellanError.invalidArgument("Cloudflare braucht die Account-ID in der Verbindung (Einstellung account_id), um Zieladressen für Email Routing anzulegen")) {
            try await adapter.createForward(address: "neu@example.com", targets: ["neu@example.org"], keepCopy: false)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func createForwardCreatesMissingDestinationAndReportsPending() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("email_routing-addresses"),
            try CloudflareFixtures.response("email_routing-address-create"),
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("email_routing-rule-create"),
        ], accountID: account)
        let forward = try await adapter.createForward(address: "Neu@example.com", targets: ["neu@example.org"], keepCopy: true)
        #expect(await transport.calls == [
            "GET /accounts/\(account)/email/routing/addresses",
            "POST /accounts/\(account)/email/routing/addresses",
            "GET /zones",
            "POST /zones/\(zoneID)/email/routing/rules",
        ])
        let requests = await transport.requests
        #expect(requests[1].object == ["email": .string("neu@example.org")])
        #expect(requests[3].object == [
            "name": .string("Kastellan: neu@example.com"),
            "enabled": .bool(true),
            "matchers": .array([.object(["type": .string("literal"), "field": .string("to"), "value": .string("neu@example.com")])]),
            "actions": .array([.object(["type": .string("forward"), "value": .array([.string("neu@example.org")])])]),
        ])
        #expect(forward.address == "neu@example.com")
        #expect(forward.targets == ["neu@example.org"])
        #expect(forward.status == .pendingVerification)
        #expect(forward.ref.providerRef == "1d28ce4b2b6d7d60cc9dbd5a4f3e2d11")
        #expect(forward.extra["keep_copy_unsupported"] == .bool(true))
        #expect(!forward.keepCopy)
    }

    @Test func createForwardWithVerifiedTargetIsActive() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("email_routing-addresses"),
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("email_routing-rule-delete"),
        ], accountID: account)
        let forward = try await adapter.createForward(address: "info@example.com", targets: ["User@example.com"], keepCopy: false)
        #expect(forward.status == .active)
        #expect(forward.extra["keep_copy_unsupported"] == nil)
        // Bekannte Adresse wird nicht noch einmal angelegt.
        #expect(await transport.calls.filter { $0.hasPrefix("POST /accounts") }.isEmpty)
    }

    @Test func createCatchAllUsesPut() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("email_routing-addresses"),
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("email_routing-catch_all"),
        ], accountID: account)
        let forward = try await adapter.createForward(address: "*@example.com", targets: ["user@example.com"], keepCopy: false)
        let request = try #require(await transport.requests.last)
        #expect(request.method == "PUT")
        #expect(request.path == "/zones/\(zoneID)/email/routing/rules/catch_all")
        #expect(request.object["matchers"] == .array([.object(["type": .string("all")])]))
        #expect(request.object["name"] == .string("Kastellan: Catch-all"))
        #expect(request.object["priority"] == nil)
        #expect(forward.address == "*@example.com")
        #expect(forward.status == .active)
        #expect(forward.extra["catch_all"] == .bool(true))
    }

    @Test func invalidAddressOrTargetsAreRejectedBeforeAnyCall() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([], accountID: account)
        await #expect(throws: KastellanError.invalidArgument("Keine gültige Adresse: kaputt")) {
            try await adapter.createForward(address: "kaputt", targets: ["a@b.de"], keepCopy: false)
        }
        await #expect(throws: KastellanError.invalidArgument("Weiterleitung braucht mindestens ein Ziel")) {
            try await adapter.createForward(address: "x@example.com", targets: [" "], keepCopy: false)
        }
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - Ändern und Löschen

    @Test func updateForwardFindsRuleAndPutsFullBody() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("email_routing-addresses"),
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("email_routing-rules"),
            try CloudflareFixtures.response("email_routing-rule-update"),
        ], accountID: account)
        let forward = try await adapter.updateForward(address: "info@example.com", targets: ["user@example.com", "old@example.net"], keepCopy: false)
        let request = try #require(await transport.requests.last)
        #expect(request.method == "PUT")
        #expect(request.path == "/zones/\(zoneID)/email/routing/rules/a7e6fb77503c41d8a7f3113c6c4ea0a6")
        #expect(request.object["name"] == .string("Info an Max"))
        #expect(request.object["enabled"] == .bool(true))
        #expect(request.object["priority"] == .int(0))
        #expect(request.object["actions"] == .array([.object(["type": .string("forward"), "value": .array([.string("user@example.com"), .string("old@example.net")])])]))
        #expect(forward.targets == ["user@example.com", "old@example.net"])
        #expect(forward.status == .pendingVerification)
    }

    @Test func updateUnknownForwardIsNotFound() async throws {
        let (adapter, _) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("email_routing-rules"),
        ])
        await #expect(throws: KastellanError.notFound("Weiterleitung nix@example.com bei Cloudflare")) {
            try await adapter.updateForward(address: "nix@example.com", targets: ["user@example.com"], keepCopy: false)
        }
    }

    @Test func deleteForwardDeletesRuleByID() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("email_routing-rules"),
            try CloudflareFixtures.response("email_routing-rule-delete"),
        ])
        try await adapter.deleteForward(address: "info@example.com")
        #expect(await transport.calls.last == "DELETE /zones/\(zoneID)/email/routing/rules/a7e6fb77503c41d8a7f3113c6c4ea0a6")
    }

    @Test func deleteCatchAllDisablesItWithDrop() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("email_routing-catch_all"),
            try CloudflareFixtures.response("email_routing-catch_all-disabled"),
        ])
        try await adapter.deleteForward(address: "*@example.com")
        let request = try #require(await transport.requests.last)
        #expect(request.method == "PUT")
        #expect(request.path == "/zones/\(zoneID)/email/routing/rules/catch_all")
        #expect(request.object == [
            "name": .string("Send to user@example.net rule."),
            "enabled": .bool(false),
            "matchers": .array([.object(["type": .string("all")])]),
            "actions": .array([.object(["type": .string("drop")])]),
        ])
    }

    @Test func addressVerificationFlag() throws {
        let json = """
        [{"email": "a@b.de", "verified": "2024-04-01T10:00:00Z"}, {"email": "c@d.de", "verified": null}, {"email": "e@f.de"}, {"email": "g@h.de", "verified": true}]
        """
        let addresses = try JSONDecoder().decode([CloudflareEmailAddress].self, from: Data(json.utf8))
        #expect(addresses.map(\.isVerified) == [true, false, false, true])
    }
}

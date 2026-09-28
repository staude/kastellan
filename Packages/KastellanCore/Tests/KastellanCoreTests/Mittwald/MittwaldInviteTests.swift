import Foundation
import Testing
@testable import KastellanCore

struct MittwaldInviteTests {
    static let project = "11111111-1111-4111-8111-111111111111"
    static let settings = ["project_id": project]

    @Test func createInviteForProjectWithRoleAndExpiry() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([MittwaldFixtures.json(#"{"id":"inv-1"}"#, status: 201)], settings: Self.settings)
        let sub = try await adapter.createSubaccount(password: "ignoriert", comment: "Willkommen", extra: ["mail_address": .string("user9@example.org"), "role": .string("emailadmin"), "expires_at": .string("2026-12-31T00:00:00Z")])
        #expect(sub.login == "user9@example.org")
        #expect(sub.ref.providerRef == "inv-1")
        #expect(sub.extra["note"] != nil)
        let req = await transport.requests[0]
        #expect(req.method == "POST" && req.path == "/projects/\(Self.project)/invites")
        #expect(req.body == .object(["mailAddress": .string("user9@example.org"), "role": .string("emailadmin"), "message": .string("Willkommen"), "membershipExpiresAt": .string("2026-12-31T00:00:00Z")]))
    }

    @Test func createInviteForCustomerAndValidation() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([MittwaldFixtures.json(#"{"id":"inv-2"}"#, status: 201)], settings: Self.settings)
        _ = try await adapter.createSubaccount(password: "", comment: nil, extra: ["mail_address": .string("buchhaltung@example.org"), "role": .string("accountant"), "customer_id": .string("c-1")])
        #expect(await transport.requests[0].path == "/customers/c-1/invites")
        await #expect(throws: KastellanError.self) { try await adapter.createSubaccount(password: "", comment: nil, extra: [:]) }
        await #expect(throws: KastellanError.self) { try await adapter.createSubaccount(password: "", comment: nil, extra: ["mail_address": .string("a@example.org"), "role": .string("accountant")]) }
    }

    @Test func deleteRemovesInviteOrMembership() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.page([#"{"id":"inv-1","mailAddress":"user9@example.org","role":"external"}"#], total: 1), MittwaldFixtures.empty(),
            MittwaldFixtures.page([], total: 0), MittwaldFixtures.page([#"{"id":"mem-1","email":"user1@example.com","role":"owner","inherited":false}"#], total: 1), MittwaldFixtures.empty(),
            MittwaldFixtures.page([], total: 0), MittwaldFixtures.page([#"{"id":"mem-2","email":"chef@example.com","role":"owner","inherited":true}"#], total: 1),
        ], settings: Self.settings)
        try await adapter.deleteSubaccount(login: "User9@example.org")
        try await adapter.deleteSubaccount(login: "user1@example.com")
        let requests = await transport.requests
        #expect(requests[1].method == "DELETE" && requests[1].path == "/project-invites/inv-1")
        #expect(requests[4].method == "DELETE" && requests[4].path == "/project-memberships/mem-1")
        await #expect(throws: KastellanError.self) { try await adapter.deleteSubaccount(login: "chef@example.com") }
        #expect(MittwaldAdapter.capabilityMatrix.supports(Capability(.subaccount, .create)))
    }
}

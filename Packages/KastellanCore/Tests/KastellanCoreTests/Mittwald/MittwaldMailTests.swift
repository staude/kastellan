import Foundation
import Testing
@testable import KastellanCore

struct MittwaldMailTests {
    static let project = "11111111-1111-4111-8111-111111111111"
    static let settings = ["project_id": project]
    static func addresses() throws -> MittwaldResponse {
        MittwaldFixtures.json(String(data: try MittwaldFixtures.data("mail-addresses"), encoding: .utf8)!, headers: ["X-Pagination-TotalCount": "2"])
    }
    static let mailboxItem = #"{"id":"m1111111-1111-4111-8111-111111111111","address":"user1@example.com","projectId":"p","isCatchAll":false,"forwardAddresses":[],"receivingDisabled":false,"mailbox":{"name":"p-abc","sendingEnabled":true,"spamProtection":{"active":true,"autoDeleteSpam":false,"folder":"spam","relocationMinSpamScore":5},"storageInBytes":{"limit":2147483648,"current":{"value":0,"updatedAt":"2026-09-01T00:00:00Z"}}}}"#

    @Test func createMailboxPostsAndReloadsWithEventTag() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.json(#"{"id":"m1111111-1111-4111-8111-111111111111"}"#, status: 201, headers: ["etag": "7"]),
            MittwaldFixtures.json(Self.mailboxItem),
        ], settings: Self.settings)
        let box = try await adapter.createMailbox(MailboxSpec(address: "User1@example.com", password: "geheim-123", quotaMB: 2048, copyTo: ["user2@example.net"], senderAliases: nil, extra: [:]))
        #expect(box.address == "user1@example.com")
        #expect(box.quotaMB == 2048)
        let requests = await transport.requests
        #expect(requests[0].method == "POST")
        #expect(requests[0].path == "/projects/\(Self.project)/mail-addresses")
        let body = try #require(requests[0].body)
        #expect(body.string("address") == "user1@example.com")
        #expect(body["isCatchAll"] == .bool(false))
        #expect(body["mailbox"]?.string("password") == "geheim-123")
        #expect(body["mailbox"]?.int("quotaInBytes") == 2_147_483_648)
        #expect(body["mailbox"]?["enableSpamProtection"] == .bool(true))
        #expect(body.strings("forwardAddresses") == ["user2@example.net"])
        #expect(requests[1].method == "GET")
        #expect(requests[1].path == "/mail-addresses/m1111111-1111-4111-8111-111111111111")
        #expect(requests[1].headers["if-event-reached"] == "7")
    }

    @Test func quotaHelperRespectsMinimumAndUnlimited() {
        #expect(MittwaldAdapter.quotaBytes(nil) == 1_073_741_824)
        #expect(MittwaldAdapter.quotaBytes(100) == 209_715_200)
        #expect(MittwaldAdapter.quotaBytes(-1) == -1)
        #expect(MittwaldAdapter.quotaBytes(4096) == 4_294_967_296)
    }

    @Test func createMailboxNeedsPassword() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([], settings: Self.settings)
        await #expect(throws: KastellanError.invalidArgument("Mittwald: ein Postfach braucht ein Passwort")) {
            try await adapter.createMailbox(MailboxSpec(address: "x@example.com", password: nil, quotaMB: nil, copyTo: nil, senderAliases: nil, extra: [:]))
        }
    }

    @Test func updateMailboxUsesPartialRoutes() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            try Self.addresses(),
            MittwaldFixtures.empty(), MittwaldFixtures.empty(), MittwaldFixtures.empty(), MittwaldFixtures.empty(),
            MittwaldFixtures.json(Self.mailboxItem),
        ], settings: Self.settings)
        _ = try await adapter.updateMailbox(MailboxSpec(address: "user1@example.com", password: "neu", quotaMB: 4096, copyTo: [], senderAliases: nil, extra: ["spam_protection": .bool(false)]))
        let requests = await transport.requests
        #expect(requests.map(\.path).dropFirst() == ["/mail-addresses/m1111111-1111-4111-8111-111111111111/quota", "/mail-addresses/m1111111-1111-4111-8111-111111111111/forward-addresses", "/mail-addresses/m1111111-1111-4111-8111-111111111111/spam-protection", "/mail-addresses/m1111111-1111-4111-8111-111111111111/password", "/mail-addresses/m1111111-1111-4111-8111-111111111111"])
        #expect(requests[1].method == "PATCH")
        #expect(requests[1].body?.int("quotaInBytes") == 4_294_967_296)
        #expect(requests[2].body?.strings("forwardAddresses") == [])
        #expect(requests[3].body?["spamProtection"]?["active"] == .bool(false))
        #expect(requests[3].body?["spamProtection"]?.string("folder") == "spam")
        #expect(requests[4].body?.string("password") == "neu")
    }

    @Test func setPasswordAndDelete() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([try Self.addresses(), MittwaldFixtures.empty(), try Self.addresses(), MittwaldFixtures.empty()], settings: Self.settings)
        try await adapter.setMailboxPassword(address: "user1@example.com", password: "pw")
        try await adapter.deleteMailbox(address: "info@example.com")
        let requests = await transport.requests
        #expect(requests[1].method == "PATCH" && requests[1].path.hasSuffix("/password"))
        #expect(requests[3].method == "DELETE" && requests[3].path == "/mail-addresses/m2222222-2222-4222-8222-222222222222")
    }

    @Test func createForwardCreatesPureForwardOrSetsTargets() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            try Self.addresses(),
            MittwaldFixtures.json(#"{"id":"m3"}"#, status: 201),
            MittwaldFixtures.json(#"{"id":"m3","address":"neu@example.com","forwardAddresses":["user9@example.org"],"receivingDisabled":false}"#),
            try Self.addresses(),
            MittwaldFixtures.empty(),
            MittwaldFixtures.json(Self.mailboxItem),
        ], settings: Self.settings)
        let pure = try await adapter.createForward(address: "Neu@example.com", targets: ["user9@example.org"], keepCopy: false)
        #expect(pure.address == "neu@example.com" && !pure.keepCopy)
        let post = await transport.requests[1]
        #expect(post.method == "POST")
        #expect(post.body == .object(["address": .string("neu@example.com"), "forwardAddresses": .array([.string("user9@example.org")])]))

        let copy = try await adapter.createForward(address: "user1@example.com", targets: ["user9@example.org"], keepCopy: true)
        #expect(copy.keepCopy)
        let patch = await transport.requests[4]
        #expect(patch.method == "PATCH" && patch.path.hasSuffix("/forward-addresses"))
    }

    @Test func createForwardOnMailboxWithoutKeepCopyFails() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([try Self.addresses()], settings: Self.settings)
        await #expect(throws: KastellanError.self) {
            try await adapter.createForward(address: "user1@example.com", targets: ["x@example.org"], keepCopy: false)
        }
    }

    @Test func deleteForwardKeepsMailbox() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([try Self.addresses(), MittwaldFixtures.empty(), try Self.addresses(), MittwaldFixtures.empty()], settings: Self.settings)
        try await adapter.deleteForward(address: "user1@example.com")
        try await adapter.deleteForward(address: "info@example.com")
        let requests = await transport.requests
        #expect(requests[1].method == "PATCH" && requests[1].body?.strings("forwardAddresses") == [])
        #expect(requests[3].method == "DELETE")
    }

    @Test func autoresponderSetAndClear() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            try Self.addresses(), MittwaldFixtures.empty(), MittwaldFixtures.json(Self.mailboxItem),
            try Self.addresses(), MittwaldFixtures.empty(),
        ], settings: Self.settings)
        let until = MittwaldDates.date("2026-09-14T00:00:00Z")
        _ = try await adapter.setAutoresponder(MailAutoresponder(ref: ResourceRef(connectionID: "c", providerRef: ""), address: "user1@example.com", active: true, subject: "Urlaub", text: "Bis bald.", until: until))
        let set = await transport.requests[1]
        #expect(set.method == "PATCH" && set.path.hasSuffix("/autoresponder"))
        #expect(set.body?["autoResponder"]?.string("message") == "Urlaub\n\nBis bald.")
        #expect(set.body?["autoResponder"]?["active"] == .bool(true))
        #expect(set.body?["autoResponder"]?.string("expiresAt") == "2026-09-14T00:00:00Z")
        #expect(set.body?["autoResponder"]?["startsAt"] == nil)
        try await adapter.clearAutoresponder(address: "user1@example.com")
        #expect(await transport.requests[4].body == .object(["autoResponder": .null]))
    }

    @Test func credentialServiceForMail() {
        let (adapter, _, _) = MittwaldFixtures.adapter([])
        #expect(adapter.credentialService(for: .mailbox) == CredentialService(host: "mail.agenturserver.de", scheme: "imaps", port: 993))
        #expect(adapter.credentialService(for: .database) == nil)
    }
}

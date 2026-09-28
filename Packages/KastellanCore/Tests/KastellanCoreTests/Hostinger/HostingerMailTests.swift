import Foundation
import Testing
@testable import KastellanCore

struct HostingerMailTests {
    static let orders = HostingerFixtures.page([#"{"id":"o-1","status":"active","is_trial":false,"seats":5,"domain":{"id":"DO1","name":"example.com"},"plan":{"name":"Business"},"created_at":"2026-01-01T00:00:00Z"}"#], page: 1, perPage: 100, total: 1)
    static let boxes = HostingerFixtures.page([
        #"{"id":"mb-1","address":"user1@example.com","status":"active","protocols":{"is_imap_enabled":true},"counts":{"forwarders":1,"aliases":0,"autoreplies":0},"is_catchall":false,"usage":{"storage_used":512000,"storage_quota":10485760},"created_at":"2026-01-01T00:00:00Z"}"#,
        #"{"id":"mb-2","address":"user2@example.com","status":"active","protocols":{},"counts":{},"is_catchall":false,"usage":{"storage_used":0,"storage_quota":10485760}}"#,
    ], page: 1, perPage: 100, total: 2)
    static let forwarders = HostingerFixtures.page([#"{"id":"fw-1","mailbox":{"id":"mb-1","address":"user1@example.com"},"destination":"user9@example.org","is_keep_copy_enabled":true,"is_active":true,"is_confirmed":false}"#], page: 1, perPage: 100, total: 1)
    static let aliases = HostingerFixtures.page([#"{"id":"al-1","address":"info@example.com","mailbox":{"id":"mb-2","address":"user2@example.com"},"is_active":true}"#], page: 1, perPage: 100, total: 1)
    static let catchalls = HostingerFixtures.page([#"{"id":"ca-1","mailbox":{"id":"mb-1","address":"user1@example.com"},"domain":"example.com","is_active":true,"is_confirmed":true}"#], page: 1, perPage: 100, total: 1)
    static let empty = HostingerFixtures.page([], page: 1, perPage: 100, total: 0)

    @Test func listMailboxesViaOrders() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([Self.orders, Self.boxes])
        let boxes = try await adapter.listMailboxes(domain: "example.com")
        #expect(boxes.map(\.address) == ["user1@example.com", "user2@example.com"])
        #expect(boxes[0].quotaMB == 10240)
        #expect(boxes[0].usedMB == 500)
        #expect(boxes[0].extra["order_id"] == .string("o-1"))
        #expect(await transport.requests[1].path == "/api/mail/v1/orders/o-1/mailboxes")
    }

    @Test func createMailboxWithCopyTargets() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            Self.orders,
            HostingerFixtures.json(#"{"id":"mb-3","address":"neu@example.com","status":"active","usage":{"storage_used":0,"storage_quota":10485760}}"#, status: 201),
            HostingerFixtures.json(#"{"id":"fw-2","destination":"user9@example.org","is_keep_copy_enabled":true,"is_confirmed":false}"#, status: 201),
        ])
        let box = try await adapter.createMailbox(MailboxSpec(address: "Neu@example.com", password: "Geheim-123!", quotaMB: 2048, copyTo: ["user9@example.org"], senderAliases: nil, extra: [:]))
        #expect(box.address == "neu@example.com")
        #expect(box.copyTo == ["user9@example.org"])
        #expect(box.extra["quota_note"] != nil)
        let requests = await transport.requests
        #expect(requests[1].method == "POST" && requests[1].path == "/api/mail/v1/orders/o-1/mailboxes")
        #expect(requests[1].body == .object(["local_part": .string("neu"), "password": .string("Geheim-123!")]))
        #expect(requests[2].path == "/api/mail/v1/mailboxes/mb-3/forwarders")
        #expect(requests[2].body?["is_keep_copy_enabled"] == .bool(true))
        await #expect(throws: KastellanError.self) { try await adapter.createMailbox(MailboxSpec(address: "x@example.com", password: nil, quotaMB: nil, copyTo: nil, senderAliases: nil, extra: [:])) }
    }

    @Test func passwordAndDeleteAndMissingOrder() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            Self.orders, Self.boxes, HostingerFixtures.message(),
            Self.orders, Self.boxes, HostingerFixtures.message(),
            Self.orders,
        ])
        try await adapter.setMailboxPassword(address: "user1@example.com", password: "Neu-123!")
        try await adapter.deleteMailbox(address: "user2@example.com")
        let requests = await transport.requests
        #expect(requests[2].method == "PATCH" && requests[2].path == "/api/mail/v1/mailboxes/mb-1/password")
        #expect(requests[5].method == "DELETE" && requests[5].path == "/api/mail/v1/mailboxes/mb-2")
        await #expect(throws: KastellanError.notFound("Hostinger: keine E-Mail-Order für example.org")) { try await adapter.deleteMailbox(address: "x@example.org") }
    }

    @Test func listForwardsCombinesForwardersAliasesCatchalls() async throws {
        let (adapter, _, _) = HostingerFixtures.adapter([Self.orders, Self.forwarders, Self.aliases, Self.catchalls])
        let forwards = try await adapter.listForwards(domain: nil)
        #expect(forwards.map(\.address) == ["*@example.com", "info@example.com", "user1@example.com"])
        #expect(forwards[2].targets == ["user9@example.org"] && forwards[2].keepCopy && forwards[2].status == .pendingVerification)
        #expect(forwards[1].targets == ["user2@example.com"] && forwards[1].extra["kind"] == .string("alias"))
        #expect(forwards[0].targets == ["user1@example.com"] && forwards[0].status == .active)
    }

    @Test func createForwardChoosesForwarderAliasOrCatchall() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            Self.orders, Self.boxes, HostingerFixtures.json(#"{"id":"fw-9","destination":"user9@example.org","is_keep_copy_enabled":false,"is_confirmed":false}"#, status: 201),
            Self.orders, Self.boxes, HostingerFixtures.json(#"{"id":"al-9","address":"sales@example.com","mailbox":{"id":"mb-2","address":"user2@example.com"},"is_active":true}"#, status: 201),
            Self.orders, Self.boxes, HostingerFixtures.json(#"{"id":"ca-9","mailbox":{"id":"mb-1","address":"user1@example.com"},"domain":"example.com","is_active":true,"is_confirmed":false}"#, status: 201),
            Self.orders, Self.boxes,
        ])
        let fw = try await adapter.createForward(address: "user1@example.com", targets: ["user9@example.org"], keepCopy: false)
        #expect(fw.extra["kind"] == .string("forwarder") && fw.status == .pendingVerification)
        #expect(await transport.requests[2].path == "/api/mail/v1/mailboxes/mb-1/forwarders")
        let alias = try await adapter.createForward(address: "sales@example.com", targets: ["user2@example.com"], keepCopy: false)
        #expect(alias.extra["kind"] == .string("alias"))
        #expect(await transport.requests[5].body == .object(["local_part": .string("sales")]))
        let catchall = try await adapter.createForward(address: "*@example.com", targets: ["user1@example.com"], keepCopy: false)
        #expect(catchall.extra["kind"] == .string("catchall") && catchall.status == .pendingVerification)
        #expect(await transport.requests[8].path == "/api/mail/v1/mailboxes/mb-1/catchalls")
        await #expect(throws: KastellanError.self) { try await adapter.createForward(address: "extern@example.com", targets: ["user9@example.org"], keepCopy: false) }
    }

    @Test func deleteForwardRemovesAllForwarderEntries() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([Self.orders, Self.forwarders, Self.aliases, Self.catchalls, HostingerFixtures.message()])
        try await adapter.deleteForward(address: "user1@example.com")
        let del = await transport.requests[4]
        #expect(del.method == "DELETE" && del.path == "/api/mail/v1/forwarders/fw-1")
    }

    @Test func autoresponderGetSetClear() async throws {
        let reply = #"{"id":"ar-1","mailbox":{"id":"mb-1","address":"user1@example.com"},"subject":"Abwesend","body":"Bis Montag.","display_name":"Erika","starts_at":"2026-09-01T00:00:00Z","ends_at":"2099-09-14T00:00:00Z"}"#
        let (adapter, transport, _) = HostingerFixtures.adapter([
            Self.orders, HostingerFixtures.page([reply], page: 1, perPage: 100, total: 1),
            Self.orders, Self.empty, Self.orders, Self.boxes, HostingerFixtures.json(reply, status: 201),
            Self.orders, HostingerFixtures.page([reply], page: 1, perPage: 100, total: 1), HostingerFixtures.message(),
        ])
        let current = try await adapter.getAutoresponder(address: "user1@example.com")
        #expect(current?.subject == "Abwesend" && current?.active == true)
        let set = try await adapter.setAutoresponder(MailAutoresponder(ref: ResourceRef(connectionID: "c", providerRef: ""), address: "user1@example.com", active: true, subject: "Urlaub", text: "Bis bald."))
        #expect(set.ref.providerRef == "ar-1")
        let post = await transport.requests[6]
        #expect(post.method == "POST" && post.path == "/api/mail/v1/mailboxes/mb-1/autoreplies")
        #expect(post.body?.string("subject") == "Urlaub" && post.body?.string("body") == "Bis bald.")
        try await adapter.clearAutoresponder(address: "user1@example.com")
        #expect(await transport.requests[9].method == "DELETE")
        #expect(adapter.credentialService(for: .mailbox)?.host == "imap.hostinger.com")
    }
}

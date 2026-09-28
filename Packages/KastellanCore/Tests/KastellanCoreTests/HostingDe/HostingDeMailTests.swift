import Foundation
import Testing
@testable import KastellanCore

struct HostingDeMailTests {
    static func one(_ index: Int) throws -> HostingDeResponse {
        let all = try JSONCoding.decoder.decode(JSONValue.self, from: HostingDeFixtures.data("mailboxes-find"))
        let item = all["response"]!.array("data")[index]
        let text = String(data: try JSONCoding.encoder.encode(item), encoding: .utf8)!
        return HostingDeFixtures.page([text], page: 1, totalPages: 1)
    }

    /// Antwort eines Schreibaufrufs: das Objekt aus der Fixture unter `response`.
    static func written(status: String = "active", index: Int = 0) throws -> HostingDeResponse {
        let all = try JSONCoding.decoder.decode(JSONValue.self, from: HostingDeFixtures.data("mailboxes-find"))
        var item = all["response"]!.array("data")[index].objectValue!
        item["status"] = .string(status)
        let text = String(data: try JSONCoding.encoder.encode(JSONValue.object(item)), encoding: .utf8)!
        return HostingDeFixtures.json(#"{"status":"\#(status == "active" ? "success" : "pending")","errors":[],"warnings":[],"metadata":{},"response":\#(text)}"#)
    }

    static let filterImap = HostingDeFilter.and([.equal("MailboxType", "ImapMailbox")]).json

    @Test func listMailboxesFiltersTypeAndDomainAndMaps() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("mailboxes-find")])
        let boxes = try await adapter.listMailboxes(domain: "Example.com")
        // Die Fixture enthält alle Typen; der Adapter mappt, was der Server liefert.
        #expect(boxes.count == 5)
        let first = try #require(boxes.first { $0.address == "user1@example.com" })
        #expect(first.quotaMB == 2048)
        #expect(first.usedMB == 120)
        #expect(first.spamFilter == "medium")
        #expect(first.copyTo == ["user2@example.net"])
        #expect(first.ref.providerRef == "mb-1")
        #expect(first.extra["productCode"] == .string("email-imap-mailbox-12m"))
        let second = try #require(boxes.first { $0.address == "user3@example.com" })
        #expect(second.spamFilter == "off")
        #expect(second.extra["isAdmin"] == .bool(true))
        let req = try #require(await transport.requests.first)
        #expect(req.method == "email/mailboxesFind")
        #expect(req.param("filter") == HostingDeFilter.and([.equal("MailboxType", "ImapMailbox"), .or([.equal("MailboxDomainName", "example.com"), .equal("MailboxDomainNameUnicode", "example.com")])]).json)
    }

    @Test func getMailboxFiltersByAddressAndType() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.one(0)])
        let box = try await adapter.getMailbox(address: "User1@example.com")
        #expect(box?.address == "user1@example.com")
        let req = try #require(await transport.requests.first)
        #expect(req.param("filter") == HostingDeFilter.and([.or([.equal("MailboxEmailAddress", "user1@example.com"), .equal("MailboxEmailAddressUnicode", "user1@example.com")]), .equal("MailboxType", "ImapMailbox")]).json)
        #expect(req.param("limit") == .int(1))
    }

    @Test func createMailboxSendsProductPasswordAndWaits() async throws {
        let (adapter, transport, sleeps) = HostingDeFixtures.adapter([
            try Self.written(status: "creating"),
            try Self.one(0),
        ])
        let box = try await adapter.createMailbox(MailboxSpec(address: "User1@example.com", password: "geheim-123", quotaMB: 2048, copyTo: ["user2@example.net"], senderAliases: nil, extra: [:]))
        #expect(box.address == "user1@example.com")
        let requests = await transport.requests
        #expect(requests[0].method == "email/mailboxCreate")
        #expect(requests[0].param("password") == .string("geheim-123"))
        let mailbox = try #require(requests[0].param("mailbox"))
        #expect(mailbox.string("type") == "ImapMailbox")
        #expect(mailbox.string("productCode") == "email-imap-mailbox-12m")
        #expect(mailbox.string("emailAddress") == "user1@example.com")
        #expect(mailbox.int("storageQuota") == 2048)
        #expect(mailbox["isAdmin"] == .bool(false))
        #expect(mailbox.strings("forwarderTargets") == ["user2@example.net"])
        #expect(mailbox["id"] == nil)
        #expect(requests[1].method == "email/mailboxesFind")
        #expect(requests[1].param("filter") == HostingDeFilter.equal("MailboxId", "mb-1").json)
        #expect(await sleeps.seconds == [])
    }

    @Test func createMailboxNeedsPassword() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([])
        await #expect(throws: KastellanError.invalidArgument("hosting.de: ein IMAP-Postfach braucht ein Passwort")) {
            try await adapter.createMailbox(MailboxSpec(address: "x@example.com", password: nil, quotaMB: nil, copyTo: nil, senderAliases: nil, extra: [:]))
        }
    }

    @Test func productCodePrecedenceExtraSettingDefault() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.written(), try Self.written()], settings: ["mailbox_product": "email-imap-bundle"])
        _ = try await adapter.createMailbox(MailboxSpec(address: "a@example.com", password: "p", quotaMB: nil, copyTo: nil, senderAliases: nil, extra: [:]))
        _ = try await adapter.createMailbox(MailboxSpec(address: "b@example.com", password: "p", quotaMB: nil, copyTo: nil, senderAliases: nil, extra: ["product_code": .string("email-imap-big")]))
        let requests = await transport.requests
        #expect(requests[0].param("mailbox")?.string("productCode") == "email-imap-bundle")
        #expect(requests[0].param("mailbox")?.int("storageQuota") == 1024)
        #expect(requests[1].param("mailbox")?.string("productCode") == "email-imap-big")
    }

    @Test func updateMailboxSendsWholeObjectWithoutReadOnlyFields() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.one(0), try Self.written()])
        _ = try await adapter.updateMailbox(MailboxSpec(address: "user1@example.com", password: nil, quotaMB: 4096, copyTo: [], senderAliases: nil, extra: [:]))
        let update = await transport.requests[1]
        #expect(update.method == "email/mailboxUpdate")
        #expect(update.param("password") == nil)
        let mailbox = try #require(update.param("mailbox"))
        #expect(mailbox.string("id") == "mb-1")
        #expect(mailbox.int("storageQuota") == 4096)
        #expect(mailbox.strings("forwarderTargets") == [])
        #expect(mailbox["spamFilter"]?.string("spamLevel") == "medium")
        #expect(mailbox["autoResponder"]?.string("subject") == "Abwesend")
        for key in ["status", "storageQuotaUsed", "paidUntil", "addDate", "lastChangeDate", "domainName", "accountId"] {
            #expect(mailbox[key] == nil, "\(key) darf nicht mitgeschickt werden")
        }
    }

    @Test func setPasswordUsesUpdateWithPassword() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.one(0), try Self.written()])
        try await adapter.setMailboxPassword(address: "user1@example.com", password: "neu-456")
        let update = await transport.requests[1]
        #expect(update.method == "email/mailboxUpdate")
        #expect(update.param("password") == .string("neu-456"))
        #expect(update.param("mailbox")?.int("storageQuota") == 2048)
    }

    @Test func deleteMailboxUsesId() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.one(0), HostingDeFixtures.json(#"{"status":"pending","errors":[],"warnings":[],"metadata":{},"response":null}"#)])
        try await adapter.deleteMailbox(address: "user1@example.com")
        let del = await transport.requests[1]
        #expect(del.method == "email/mailboxDelete")
        #expect(del.param("mailboxId") == .string("mb-1"))
    }

    @Test func unknownMailboxIsNotFound() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([HostingDeFixtures.page([], page: 1, totalPages: 0, totalEntries: 0)])
        await #expect(throws: KastellanError.notFound("Postfach nix@example.com bei hosting.de")) {
            try await adapter.deleteMailbox(address: "nix@example.com")
        }
    }

    // MARK: Weiterleitungen

    @Test func listForwardsMapsForwarderAndCatchall() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("mailboxes-find")])
        let forwards = try await adapter.listForwards(domain: nil)
        let info = try #require(forwards.first { $0.address == "info@example.com" })
        #expect(info.targets == ["user1@example.com", "user4@example.net"])
        #expect(!info.keepCopy)
        #expect(info.extra["forwarderType"] == .string("externalForwarder"))
        let catchall = try #require(forwards.first { $0.address == "*@example.com" })
        #expect(catchall.targets == ["user1@example.com"])
        let req = try #require(await transport.requests.first)
        #expect(req.param("filter") == HostingDeFilter.and([.or([.equal("MailboxType", "Forwarder"), .equal("MailboxType", "Catchall")])]).json)
    }

    @Test func createForwardBuildsForwarderWithType() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.written(index: 2)])
        let fw = try await adapter.createForward(address: "Info@example.com", targets: ["user1@example.com", "user4@example.net"], keepCopy: false)
        #expect(fw.address == "info@example.com")
        let mailbox = try #require(await transport.requests[0].param("mailbox"))
        #expect(mailbox.string("type") == "Forwarder")
        #expect(mailbox.string("forwarderType") == "externalForwarder")
        #expect(mailbox.string("productCode") == "email-forwarder-external-12m")
        #expect(mailbox.strings("forwarderTargets") == ["user1@example.com", "user4@example.net"])
        #expect(await transport.requests[0].param("password") == nil)
    }

    @Test func createForwardForWildcardBuildsCatchall() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.written(index: 3)])
        _ = try await adapter.createForward(address: "*@example.com", targets: ["user1@example.com"], keepCopy: false)
        let mailbox = try #require(await transport.requests[0].param("mailbox"))
        #expect(mailbox.string("type") == "Catchall")
        #expect(mailbox.string("forwarderTarget") == "user1@example.com")
        #expect(mailbox.string("productCode") == "email-catchall-12m")
    }

    @Test func createForwardWithKeepCopySetsMailboxTargets() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.one(0), try Self.written()])
        let fw = try await adapter.createForward(address: "user1@example.com", targets: ["user9@example.org"], keepCopy: true)
        #expect(fw.keepCopy)
        let update = await transport.requests[1]
        #expect(update.method == "email/mailboxUpdate")
        #expect(update.param("mailbox")?.strings("forwarderTargets") == ["user9@example.org"])
    }

    @Test func createForwardWithKeepCopyWithoutMailboxFails() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([HostingDeFixtures.page([], page: 1, totalPages: 0, totalEntries: 0)])
        await #expect(throws: KastellanError.self) {
            try await adapter.createForward(address: "neu@example.com", targets: ["x@example.org"], keepCopy: true)
        }
    }

    @Test func deleteForwardFallsBackToClearingMailboxTargets() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            HostingDeFixtures.page([], page: 1, totalPages: 0, totalEntries: 0),
            try Self.one(0),
            try Self.written(),
        ])
        try await adapter.deleteForward(address: "user1@example.com")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[2].method == "email/mailboxUpdate")
        #expect(requests[2].param("mailbox")?.strings("forwarderTargets") == [])
    }

    @Test func forwarderTypeHelper() {
        #expect(HostingDeAdapter.forwarderType(address: "a@example.com", targets: ["b@example.com"]) == "internalForwarder")
        #expect(HostingDeAdapter.forwarderType(address: "a@example.com", targets: ["b@example.com", "c@example.net"]) == "externalForwarder")
    }

    // MARK: Autoresponder

    @Test func autoresponderReadSetClear() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.one(0), try Self.one(1), try Self.written(), try Self.one(0), try Self.written()])
        let current = try await adapter.getAutoresponder(address: "user1@example.com")
        #expect(current?.active == true)
        #expect(current?.subject == "Abwesend")
        #expect(current?.text == "Bin bis Montag nicht da.")
        #expect(current?.until == HostingDeDates.date("2026-09-14T00:00:00Z"))

        let set = try await adapter.setAutoresponder(MailAutoresponder(ref: ResourceRef(connectionID: "c", providerRef: ""), address: "user3@example.com", active: true, subject: "Urlaub", text: "Bis bald."))
        _ = set
        let update = await transport.requests[2]
        let responder = try #require(update.param("mailbox")?["autoResponder"])
        #expect(responder.string("subject") == "Urlaub")
        #expect(responder.string("body") == "Bis bald.")
        #expect(responder["active"] == .bool(true))
        #expect(responder["enabled"] == .bool(true))
        #expect(responder["start"] == nil)

        try await adapter.clearAutoresponder(address: "user1@example.com")
        let clear = await transport.requests[4]
        #expect(clear.param("mailbox")?["autoResponder"]?["active"] == .bool(false))
        #expect(clear.param("mailbox")?["autoResponder"]?["enabled"] == .bool(false))
        #expect(clear.param("mailbox")?["autoResponder"]?.string("subject") == "Abwesend")
    }

    // MARK: Mailinglisten

    @Test func mailingListsMapAndCreateNeedsOwners() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("mailboxes-find"), try Self.written(index: 4)])
        let lists = try await adapter.listMailingLists(domain: nil)
        let team = try #require(lists.first { $0.address == "team@example.com" })
        #expect(team.members == ["user1@example.com", "user5@example.org"])
        #expect(team.moderated)
        #expect(team.extra["owners"] == .array([.string("user3@example.com")]))

        await #expect(throws: KastellanError.invalidArgument("hosting.de: eine Mailingliste braucht mindestens einen Eigentümer (extra.owners)")) {
            try await adapter.createMailingList(address: "neu@example.com", members: [], extra: [:])
        }
        _ = try await adapter.createMailingList(address: "Team@example.com", members: ["user1@example.com"], extra: ["owners": .array([.string("user3@example.com")]), "name": .string("Team")])
        let mailbox = try #require(await transport.requests[1].param("mailbox"))
        #expect(mailbox.string("type") == "MailingList")
        #expect(mailbox.string("productCode") == "email-mailinglist-team-v1-12m")
        #expect(mailbox.string("accessMode") == "members")
        #expect(mailbox.string("replyToMode") == "list")
        #expect(mailbox.strings("owners") == ["user3@example.com"])
        #expect(mailbox.strings("members") == ["user1@example.com"])
    }

    @Test func updateMailingListReplacesMembers() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.one(4), try Self.written(index: 4)])
        _ = try await adapter.updateMailingList(address: "team@example.com", members: ["a@example.com"], extra: ["access_mode": .string("everyone")])
        let mailbox = try #require(await transport.requests[1].param("mailbox"))
        #expect(mailbox.strings("members") == ["a@example.com"])
        #expect(mailbox.string("accessMode") == "everyone")
        #expect(mailbox.string("name") == "Team")
        #expect(mailbox["status"] == nil)
    }

    @Test func credentialServiceForMail() {
        let (adapter, _, _) = HostingDeFixtures.adapter([])
        #expect(adapter.credentialService(for: .mailbox) == CredentialService(host: "mail.hosting.de", scheme: "imaps", port: 993))
        #expect(adapter.credentialService(for: .ftpUser) == nil)
        let (custom, _, _) = HostingDeFixtures.adapter([], settings: ["mail_host": "mail.example.net"])
        #expect(custom.credentialService(for: .mailbox)?.host == "mail.example.net")
    }
}

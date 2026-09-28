import Foundation
import Testing
@testable import KastellanCore

struct KASAdapterMailTests {
    @Test func capabilityMatrixCoversMailResources() {
        let m = KASAdapter.capabilityMatrix
        #expect(m.supports(Capability(.mailbox, .setPassword)))
        #expect(m.supports(Capability(.mailbox, .delete)))
        #expect(m.supports(Capability(.mailForward, .update)))
        #expect(!m.supports(Capability(.mailForward, .get)))
        #expect(m.supports(Capability(.mailAutoresponder, .get)))
        #expect(m.supports(Capability(.mailAutoresponder, .update)))
        #expect(m.supports(Capability(.mailAutoresponder, .delete)))
        #expect(!m.supports(Capability(.mailAutoresponder, .create)))
        #expect(m.supports(Capability(.mailingList, .create)))
        #expect(!m.supports(Capability(.mailingList, .get)))
        let adapter: any ProviderAdapter = KASAdapter(connection: Connection(profileID: "c", provider: "allinkl", label: ""), secrets: InMemorySecretProvider())
        #expect(adapter as? any MailboxAdapter != nil)
        #expect(adapter as? any MailAutoresponderAdapter != nil)
        #expect(adapter as? any MailingListAdapter != nil)
    }

    // MARK: - Mailbox

    @Test func listMailboxesMapsFixture() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_mailaccounts")])
        let boxes = try await adapter.listMailboxes(domain: nil)
        #expect(boxes.map(\.address) == ["webseite@beispiel-verein.de", "planer@beispiel-app.de"])
        let first = try #require(boxes.first)
        #expect(first.ref.providerRef == "m0abcd01")
        #expect(first.status == "active")
        #expect(first.usedMB == 47)
        #expect(first.quotaMB == nil)
        #expect(first.spamFilter == "pdw,sf")
        #expect(first.senderAliases.isEmpty)
        #expect(first.copyTo.isEmpty)
        #expect(first.localPart == "webseite")
        #expect(first.domainPart == "beispiel-verein.de")
        // Provider-Felder in extra, Passwort und Duplikate nicht
        #expect(first.extra["mail_responder"] == .string("N"))
        #expect(first.extra["quota_rule"] == .string("0"))
        #expect(first.extra["mail_xlist_trash"] == .string("Papierkorb"))
        #expect(first.extra["mail_password"] == nil)
        #expect(first.extra["mail_adresses"] == nil)
        #expect(first.extra["mail_copy_adress"] == nil)
        #expect(first.extra["mail_login"] == nil)
    }

    @Test func listMailboxesFiltersByDomain() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_mailaccounts")])
        let boxes = try await adapter.listMailboxes(domain: "Beispiel-App.de")
        #expect(boxes.map(\.address) == ["planer@beispiel-app.de"])
    }

    @Test func mailboxWithCopyAndAliases() async throws {
        let (adapter, _) = try KASFixtures.adapter([
            KASFixtures.mapArrayResponse("get_mailaccounts", items: [[
                "mail_login": "m1", "mail_addresses": "a@example.com,b@example.com", "mail_copy_address": "x@example.org, y@example.org",
                "mail_sender_alias": "alias@example.com", "mail_is_active": "N", "used_mailaccount_space": "0.4",
            ]]),
        ])
        let box = try #require(try await adapter.getMailbox(address: "A@example.com"))
        #expect(box.address == "a@example.com")
        #expect(box.copyTo == ["x@example.org", "y@example.org"])
        #expect(box.senderAliases == ["alias@example.com"])
        #expect(box.status == "inactive")
        #expect(box.usedMB == 0)
        #expect(box.extra["addresses"] == .array([.string("a@example.com"), .string("b@example.com")]))
    }

    @Test func getMailboxUnknownIsNil() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_mailaccounts")])
        #expect(try await adapter.getMailbox(address: "fehlt@example.com") == nil)
    }

    @Test func createMailboxSendsLocalAndDomainPart() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_mailaccount", returnInfo: "m0neu"),
            try KASFixtures.response("get_mailaccounts"),
        ])
        let spec = MailboxSpec(address: "planer@beispiel-app.de", password: "Sehr-geheim-1", quotaMB: 500,
                               copyTo: ["kopie@example.com"], senderAliases: ["alias@example.com"], extra: ["mail_allow_nets": .string("0.0.0.0/0")])
        let box = try await adapter.createMailbox(spec)
        #expect(box.ref.providerRef == "m0abcd02")
        let add = try #require(await transport.requests.first { $0.action == "add_mailaccount" })
        #expect(add.requestParams == [
            "local_part": "planer", "domain_part": "beispiel-app.de", "mail_password": "Sehr-geheim-1",
            "copy_adress": "kopie@example.com", "mail_sender_alias": "alias@example.com", "mail_allow_nets": "0.0.0.0/0",
        ])
        // Passwort taucht nirgends im Ergebnis auf.
        let json = String(decoding: try JSONEncoder().encode(box), as: UTF8.self)
        #expect(!json.contains("Sehr-geheim-1"))
    }

    @Test func createMailboxFallsBackToReturnedLogin() async throws {
        let (adapter, _) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_mailaccount", returnInfo: "m0neu"),
            KASFixtures.mapArrayResponse("get_mailaccounts", items: []),
        ])
        let box = try await adapter.createMailbox(MailboxSpec(address: "neu@example.com", password: "pw"))
        #expect(box.ref.providerRef == "m0neu")
        #expect(box.address == "neu@example.com")
    }

    @Test func createMailboxRequiresPasswordAndValidAddress() async throws {
        let (adapter, _) = try KASFixtures.adapter([])
        await #expect(throws: KastellanError.self) { try await adapter.createMailbox(MailboxSpec(address: "neu@example.com")) }
        await #expect(throws: KastellanError.self) { try await adapter.createMailbox(MailboxSpec(address: "ohne-at", password: "x")) }
    }

    @Test func updateMailboxUsesLogin() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            try KASFixtures.response("get_mailaccounts"),
            KASFixtures.scalarResponse("update_mailaccount", returnInfo: "TRUE"),
            try KASFixtures.response("get_mailaccounts"),
        ])
        let box = try await adapter.updateMailbox(MailboxSpec(address: "webseite@beispiel-verein.de", copyTo: ["k@example.com"]))
        #expect(box.ref.providerRef == "m0abcd01")
        let update = try #require(await transport.requests.first { $0.action == "update_mailaccount" })
        #expect(update.requestParams == ["mail_login": "m0abcd01", "copy_adress": "k@example.com"])
    }

    @Test func setPasswordAndDeleteUseLogin() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            try KASFixtures.response("get_mailaccounts"),
            KASFixtures.scalarResponse("update_mailaccount", returnInfo: "TRUE"),
            try KASFixtures.response("get_mailaccounts"),
            KASFixtures.scalarResponse("delete_mailaccount", returnInfo: "TRUE"),
        ])
        try await adapter.setMailboxPassword(address: "planer@beispiel-app.de", password: "Neu-1234")
        try await adapter.deleteMailbox(address: "planer@beispiel-app.de")
        let requests = await transport.requests
        #expect(requests[2].requestParams == ["mail_login": "m0abcd02", "mail_password": "Neu-1234"])
        #expect(requests.last?.action == "delete_mailaccount")
        #expect(requests.last?.requestParams == ["mail_login": "m0abcd02"])
    }

    @Test func unknownMailboxIsNotFound() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_mailaccounts")])
        await #expect(throws: KastellanError.notFound("Postfach nix@example.com")) {
            try await adapter.deleteMailbox(address: "nix@example.com")
        }
    }

    // MARK: - Autoresponder

    @Test func getAutoresponderDerivesFromMailbox() async throws {
        let (adapter, _) = try KASFixtures.adapter([
            KASFixtures.mapArrayResponse("get_mailaccounts", items: [[
                "mail_login": "m1", "mail_addresses": "urlaub@example.com", "mail_responder": "Y",
                "mail_responder_text": "Bin im Urlaub.", "mail_responder_displayname": "Max", "mail_responder_content_type": "text",
            ]]),
        ])
        let responder = try #require(try await adapter.getAutoresponder(address: "urlaub@example.com"))
        #expect(responder.active)
        #expect(responder.text == "Bin im Urlaub.")
        #expect(responder.address == "urlaub@example.com")
        #expect(responder.ref.providerRef == "m1")
        #expect(responder.extra["displayname"] == .string("Max"))
    }

    @Test func inactiveAutoresponderFromFixture() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_mailaccounts"), try KASFixtures.response("get_mailaccounts")])
        let responder = try #require(try await adapter.getAutoresponder(address: "planer@beispiel-app.de"))
        #expect(!responder.active)
        #expect(responder.text == "")
        #expect(try await adapter.getAutoresponder(address: "fehlt@example.com") == nil)
    }

    @Test func setAutoresponderUpdatesMailaccount() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            try KASFixtures.response("get_mailaccounts"),
            KASFixtures.scalarResponse("update_mailaccount", returnInfo: "TRUE"),
            KASFixtures.mapArrayResponse("get_mailaccounts", items: [[
                "mail_login": "m0abcd02", "mail_addresses": "planer@beispiel-app.de", "mail_responder": "Y", "mail_responder_text": "Bis Montag.",
            ]]),
        ])
        let wanted = MailAutoresponder(ref: ResourceRef(connectionID: "", providerRef: ""), address: "planer@beispiel-app.de",
                                       active: true, subject: "Abwesend", text: "Bis Montag.")
        let result = try await adapter.setAutoresponder(wanted)
        #expect(result.active)
        #expect(result.text == "Bis Montag.")
        #expect(result.ref.providerRef == "m0abcd02")
        #expect(result.extra["subject"] == .string("Abwesend"))
        let update = try #require(await transport.requests.first { $0.action == "update_mailaccount" })
        #expect(update.requestParams == ["mail_login": "m0abcd02", "responder": "Y", "responder_text": "Bis Montag."])
    }

    @Test func clearAutoresponderSendsN() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            try KASFixtures.response("get_mailaccounts"),
            KASFixtures.scalarResponse("update_mailaccount", returnInfo: "TRUE"),
        ])
        try await adapter.clearAutoresponder(address: "webseite@beispiel-verein.de")
        #expect(await transport.requests.last?.requestParams == ["mail_login": "m0abcd01", "responder": "N", "responder_text": ""])
    }

    // MARK: - Weiterleitung

    @Test func listForwardsMapsFixture() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_mailforwards")])
        let forwards = try await adapter.listForwards(domain: nil)
        #expect(forwards.map(\.address) == ["info@beispiel-aktion.org", "kino@beispiel-verein.de"])
        let first = try #require(forwards.first)
        #expect(first.ref.providerRef == "info@beispiel-aktion.org")
        #expect(first.targets == ["user@example.net"])
        #expect(!first.keepCopy)
        #expect(first.status == .active)
        #expect(first.extra["mail_forward_spamfilter"] == .string("kaspdw"))
        #expect(first.extra["mail_forward_adress"] == nil)
    }

    @Test func listForwardsFiltersByDomain() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_mailforwards")])
        let forwards = try await adapter.listForwards(domain: "beispiel-verein.de")
        #expect(forwards.map(\.address) == ["kino@beispiel-verein.de"])
    }

    @Test func multipleTargetsAreSplit() async throws {
        let (adapter, _) = try KASFixtures.adapter([
            KASFixtures.mapArrayResponse("get_mailforwards", items: [["mail_forward_address": "x@example.com", "mail_forward_targets": "a@b.de, c@d.de"]]),
        ])
        #expect(try await adapter.listForwards(domain: nil).first?.targets == ["a@b.de", "c@d.de"])
    }

    @Test func createForwardNumbersTargets() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_mailforward", returnInfo: "TRUE"),
            try KASFixtures.response("get_mailforwards"),
        ])
        let forward = try await adapter.createForward(address: "info@beispiel-aktion.org", targets: ["user@example.net", "zweite@example.com"], keepCopy: true)
        #expect(forward.targets == ["user@example.net"])
        #expect(!forward.keepCopy)
        #expect(forward.extra["keep_copy_unsupported"] == .bool(true))
        let add = try #require(await transport.requests.first { $0.action == "add_mailforward" })
        #expect(add.requestParams == [
            "local_part": "info", "domain_part": "beispiel-aktion.org", "target_1": "user@example.net", "target_2": "zweite@example.com",
        ])
    }

    @Test func createForwardWithoutTargetsFails() async throws {
        let (adapter, _) = try KASFixtures.adapter([])
        await #expect(throws: KastellanError.self) { try await adapter.createForward(address: "x@example.com", targets: [" "], keepCopy: false) }
    }

    @Test func updateAndDeleteForward() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("update_mailforward", returnInfo: "TRUE"),
            KASFixtures.mapArrayResponse("get_mailforwards", items: []),
            KASFixtures.scalarResponse("delete_mailforward", returnInfo: "TRUE"),
        ])
        let updated = try await adapter.updateForward(address: "kino@beispiel-verein.de", targets: ["neu@example.com"], keepCopy: false)
        #expect(updated.targets == ["neu@example.com"])
        #expect(updated.extra["keep_copy_unsupported"] == nil)
        try await adapter.deleteForward(address: "kino@beispiel-verein.de")
        let requests = await transport.requests
        #expect(requests[1].requestParams == ["mail_forward": "kino@beispiel-verein.de", "target_1": "neu@example.com"])
        #expect(requests.last?.action == "delete_mailforward")
        #expect(requests.last?.requestParams == ["mail_forward": "kino@beispiel-verein.de"])
    }

    // MARK: - Mailingliste (ohne Fixture)

    @Test func mailingListBestEffortMapping() async throws {
        let (adapter, _) = try KASFixtures.adapter([
            KASFixtures.mapArrayResponse("get_mailinglists", items: [
                ["mailinglist_name": "team@example.com", "mailinglist_members": "a@example.com,b@example.com", "mailinglist_comment": "Team"],
                ["mailinglist_name": "news@example.org", "mailinglist_password": "geheim"],
            ]),
        ])
        let lists = try await adapter.listMailingLists(domain: "example.com")
        #expect(lists.count == 1)
        let team = try #require(lists.first)
        #expect(team.address == "team@example.com")
        #expect(team.members == ["a@example.com", "b@example.com"])
        #expect(team.extra["mailinglist_comment"] == .string("Team"))
        #expect(team.extra["mailinglist_password"] == nil)
    }

    @Test func mailingListWriteParameters() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_mailinglist", returnInfo: "TRUE"),
            KASFixtures.mapArrayResponse("get_mailinglists", items: []),
            KASFixtures.scalarResponse("update_mailinglist", returnInfo: "TRUE"),
            KASFixtures.mapArrayResponse("get_mailinglists", items: []),
            KASFixtures.scalarResponse("delete_mailinglist", returnInfo: "TRUE"),
        ])
        let created = try await adapter.createMailingList(address: "team@example.com", members: ["a@example.com"], extra: ["mailinglist_password": .string("pw")])
        #expect(created.members == ["a@example.com"])
        _ = try await adapter.updateMailingList(address: "team@example.com", members: ["b@example.com"], extra: [:])
        try await adapter.deleteMailingList(address: "team@example.com")
        let requests = await transport.requests
        #expect(requests[1].requestParams == ["local_part": "team", "domain_part": "example.com", "mailinglist_members": "a@example.com", "mailinglist_password": "pw"])
        #expect(requests[3].requestParams == ["mailinglist_name": "team@example.com", "mailinglist_members": "b@example.com"])
        #expect(requests.last?.requestParams == ["mailinglist_name": "team@example.com"])
    }
}

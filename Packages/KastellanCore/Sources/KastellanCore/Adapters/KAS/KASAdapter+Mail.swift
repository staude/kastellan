import Foundation

// KAS-Funktionen für Postfächer, Weiterleitungen, Autoresponder und Mailinglisten.
// Feldnamen für Postfächer und Weiterleitungen stammen aus echten Antworten (Fixtures
// `get_mailaccounts`, `get_mailforwards`). KAS führt einige Felder doppelt (`mail_adresses` und
// `mail_addresses`, `copy_adress` und `copy_address`); beim Senden gilt die KAS-Schreibweise
// `copy_adress`. Mailinglisten haben kein Fixture, Feldnamen dort sind geraten.

// MARK: - Mailbox

extension KASAdapter: MailboxAdapter {
    static let mailboxMapped: Set<String> = [
        "mail_login", "mail_addresses", "mail_adresses", "mail_copy_address", "mail_copy_adress",
        "mail_sender_alias", "mail_spamfilter", "used_mailaccount_space", "mail_is_active",
    ]

    /// Rohes KAS-Postfach samt Login, für Autoresponder und Schreibzugriffe.
    struct RawMailbox {
        let login: String
        let item: KASValue
        let mailbox: Mailbox
    }

    func rawMailbox(from item: KASValue) -> RawMailbox? {
        guard let login = item.string("mail_login") else { return nil }
        let addresses = Self.list(item.string("mail_addresses") ?? item.string("mail_adresses"))
        guard let address = addresses.first else { return nil }
        var extra = Self.extra(from: item, excluding: Self.mailboxMapped)
        if addresses.count > 1 { extra["addresses"] = .array(addresses.map(JSONValue.string)) }
        let used = item.double("used_mailaccount_space").map { Int($0.rounded()) }
        let mailbox = Mailbox(
            ref: ref(login),
            address: address,
            quotaMB: nil,
            usedMB: used,
            status: item.bool("mail_is_active") == false ? "inactive" : "active",
            spamFilter: item.string("mail_spamfilter"),
            senderAliases: Self.list(item.string("mail_sender_alias")),
            copyTo: Self.list(item.string("mail_copy_address") ?? item.string("mail_copy_adress")),
            extra: extra
        )
        return RawMailbox(login: login, item: item, mailbox: mailbox)
    }

    func rawMailboxes() async throws -> [RawMailbox] {
        try await items("get_mailaccounts").compactMap(rawMailbox(from:))
    }

    func findRawMailbox(address: String) async throws -> RawMailbox? {
        let wanted = address.lowercased()
        return try await rawMailboxes().first { $0.mailbox.address.lowercased() == wanted }
    }

    func requireRawMailbox(address: String) async throws -> RawMailbox {
        guard let raw = try await findRawMailbox(address: address) else {
            throw KastellanError.notFound("Postfach \(address)")
        }
        return raw
    }

    public func listMailboxes(domain: String?) async throws -> [Mailbox] {
        let all = try await rawMailboxes().map(\.mailbox)
        guard let domain, !domain.isEmpty else { return all }
        let wanted = domain.lowercased()
        return all.filter { $0.domainPart.lowercased() == wanted }
    }

    public func getMailbox(address: String) async throws -> Mailbox? {
        try await findRawMailbox(address: address)?.mailbox
    }

    /// Gemeinsame Parameter für `add_mailaccount` und `update_mailaccount`.
    private static func mailboxParams(_ spec: MailboxSpec) -> [String: String] {
        var params = Self.params(from: spec.extra)
        if let password = spec.password, !password.isEmpty { params["mail_password"] = password }
        if let copy = spec.copyTo { params["copy_adress"] = copy.joined(separator: ",") }
        if let aliases = spec.senderAliases { params["mail_sender_alias"] = aliases.joined(separator: ",") }
        return params
    }

    public func createMailbox(_ spec: MailboxSpec) async throws -> Mailbox {
        let (local, domain) = try Self.split(address: spec.address)
        guard let password = spec.password, !password.isEmpty else {
            throw KastellanError.invalidArgument("KAS braucht ein Passwort für ein neues Postfach")
        }
        var params = Self.mailboxParams(spec)
        params["local_part"] = local
        params["domain_part"] = domain
        params["mail_password"] = password
        let response = try await call("add_mailaccount", params)
        if let box = try await getMailbox(address: spec.address) { return box }
        let login = response.returnInfo.string ?? spec.address
        return Mailbox(ref: ref(login), address: spec.address, status: "active",
                       senderAliases: spec.senderAliases ?? [], copyTo: spec.copyTo ?? [])
    }

    public func updateMailbox(_ spec: MailboxSpec) async throws -> Mailbox {
        let raw = try await requireRawMailbox(address: spec.address)
        var params = Self.mailboxParams(spec)
        params["mail_login"] = raw.login
        try await call("update_mailaccount", params)
        return try await getMailbox(address: spec.address) ?? raw.mailbox
    }

    public func setMailboxPassword(address: String, password: String) async throws {
        guard !password.isEmpty else { throw KastellanError.invalidArgument("Passwort ist leer") }
        let raw = try await requireRawMailbox(address: address)
        try await call("update_mailaccount", ["mail_login": raw.login, "mail_password": password])
    }

    public func deleteMailbox(address: String) async throws {
        let raw = try await requireRawMailbox(address: address)
        try await call("delete_mailaccount", ["mail_login": raw.login])
    }
}

// MARK: - Autoresponder

extension KASAdapter: MailAutoresponderAdapter {
    func autoresponder(from raw: RawMailbox) -> MailAutoresponder {
        var extra: Extra = [:]
        if let name = raw.item.string("mail_responder_displayname") { extra["displayname"] = .string(name) }
        if let type = raw.item.string("mail_responder_content_type") { extra["content_type"] = .string(type) }
        return MailAutoresponder(
            ref: ref(raw.login),
            address: raw.mailbox.address,
            active: raw.item.bool("mail_responder") ?? false,
            subject: nil,
            text: raw.item.string("mail_responder_text") ?? "",
            extra: extra
        )
    }

    public func getAutoresponder(address: String) async throws -> MailAutoresponder? {
        try await findRawMailbox(address: address).map(autoresponder(from:))
    }

    /// KAS kennt weder Betreff noch Zeitraum; Betreff wird in `extra` mitgeführt, Zeitraum ignoriert.
    public func setAutoresponder(_ responder: MailAutoresponder) async throws -> MailAutoresponder {
        let raw = try await requireRawMailbox(address: responder.address)
        var params: [String: String] = [
            "mail_login": raw.login,
            "responder": Self.yn(responder.active),
            "responder_text": responder.text,
        ]
        if let name = responder.extra["displayname"]?.stringValue { params["mail_responder_displayname"] = name }
        try await call("update_mailaccount", params)
        var result = try await getAutoresponder(address: responder.address) ?? responder
        if let subject = responder.subject { result.extra["subject"] = .string(subject) }
        return result
    }

    public func clearAutoresponder(address: String) async throws {
        let raw = try await requireRawMailbox(address: address)
        try await call("update_mailaccount", ["mail_login": raw.login, "responder": "N", "responder_text": ""])
    }
}

// MARK: - Weiterleitung

extension KASAdapter: MailForwardAdapter {
    static let forwardMapped: Set<String> = ["mail_forward_address", "mail_forward_adress", "mail_forward_targets"]

    func forward(from item: KASValue) -> MailForward? {
        guard let address = item.string("mail_forward_address") ?? item.string("mail_forward_adress") else { return nil }
        return MailForward(
            ref: ref(address),
            address: address,
            targets: Self.list(item.string("mail_forward_targets")),
            keepCopy: false,
            status: .active,
            extra: Self.extra(from: item, excluding: Self.forwardMapped)
        )
    }

    func findForward(address: String) async throws -> MailForward? {
        let wanted = address.lowercased()
        return try await listForwards(domain: nil).first { $0.address.lowercased() == wanted }
    }

    public func listForwards(domain: String?) async throws -> [MailForward] {
        let all = try await items("get_mailforwards").compactMap(forward(from:))
        guard let domain, !domain.isEmpty else { return all }
        let wanted = domain.lowercased()
        return all.filter { $0.address.split(separator: "@").last.map { $0.lowercased() } == wanted }
    }

    /// `target_1` bis `target_N`.
    private static func targetParams(_ targets: [String]) throws -> [String: String] {
        let clean = targets.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { throw KastellanError.invalidArgument("Weiterleitung braucht mindestens ein Ziel") }
        var params: [String: String] = [:]
        for (index, target) in clean.enumerated() { params["target_\(index + 1)"] = target }
        return params
    }

    /// KAS kann keine Kopie im Postfach behalten; der Wunsch wird nur in `extra` vermerkt.
    private static func noteKeepCopy(_ forward: MailForward, requested: Bool) -> MailForward {
        var f = forward
        if requested { f.extra["keep_copy_unsupported"] = .bool(true) }
        return f
    }

    public func createForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        let (local, domain) = try Self.split(address: address)
        var params = try Self.targetParams(targets)
        params["local_part"] = local
        params["domain_part"] = domain
        try await call("add_mailforward", params)
        let forward = try await findForward(address: address)
            ?? MailForward(ref: ref(address), address: address, targets: targets)
        return Self.noteKeepCopy(forward, requested: keepCopy)
    }

    public func updateForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        var params = try Self.targetParams(targets)
        params["mail_forward"] = address
        try await call("update_mailforward", params)
        let forward = try await findForward(address: address)
            ?? MailForward(ref: ref(address), address: address, targets: targets)
        return Self.noteKeepCopy(forward, requested: keepCopy)
    }

    public func deleteForward(address: String) async throws {
        try await call("delete_mailforward", ["mail_forward": address])
    }
}

// MARK: - Mailingliste (ohne Fixture, Feldnamen geraten)

extension KASAdapter: MailingListAdapter {
    static let mailingListMapped: Set<String> = ["mailinglist_name", "mailinglist_address", "mailinglist_members"]

    func mailingList(from item: KASValue) -> MailingList? {
        guard let address = item.string("mailinglist_name") ?? item.string("mailinglist_address") else { return nil }
        return MailingList(
            ref: ref(address),
            address: address,
            members: Self.list(item.string("mailinglist_members")),
            moderated: false,
            extra: Self.extra(from: item, excluding: Self.mailingListMapped)
        )
    }

    func findMailingList(address: String) async throws -> MailingList? {
        let wanted = address.lowercased()
        return try await listMailingLists(domain: nil).first { $0.address.lowercased() == wanted }
    }

    public func listMailingLists(domain: String?) async throws -> [MailingList] {
        let all = try await items("get_mailinglists").compactMap(mailingList(from:))
        guard let domain, !domain.isEmpty else { return all }
        let wanted = domain.lowercased()
        return all.filter { $0.address.split(separator: "@").last.map { $0.lowercased() } == wanted }
    }

    private static func mailingListParams(members: [String], extra: Extra) -> [String: String] {
        var params = Self.params(from: extra)
        if !members.isEmpty { params["mailinglist_members"] = members.joined(separator: ",") }
        return params
    }

    public func createMailingList(address: String, members: [String], extra: Extra) async throws -> MailingList {
        let (local, domain) = try Self.split(address: address)
        var params = Self.mailingListParams(members: members, extra: extra)
        params["local_part"] = local
        params["domain_part"] = domain
        try await call("add_mailinglist", params)
        return try await findMailingList(address: address)
            ?? MailingList(ref: ref(address), address: address, members: members)
    }

    public func updateMailingList(address: String, members: [String], extra: Extra) async throws -> MailingList {
        var params = Self.mailingListParams(members: members, extra: extra)
        params["mailinglist_name"] = address
        try await call("update_mailinglist", params)
        return try await findMailingList(address: address)
            ?? MailingList(ref: ref(address), address: address, members: members)
    }

    public func deleteMailingList(address: String) async throws {
        try await call("delete_mailinglist", ["mailinglist_name": address])
    }
}

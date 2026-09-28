import Foundation

// E-Mail bei hosting.de: ein Mailbox-Objekt mit Diskriminator `type` (ImapMailbox, Forwarder,
// SmtpForwarder, MailingList, Catchall) über `mailboxesFind`, `mailboxCreate`, `mailboxUpdate`,
// `mailboxDelete`. Das Passwort ist ein eigener Parameter neben dem Objekt und nie lesbar.
// `mailboxUpdate` erwartet das komplette Objekt, deshalb read-modify-write. Anlage braucht einen
// `productCode` (aus `extra.product_code`, sonst Verbindungs-Einstellung, sonst Standard) und
// löst eine Bestellung aus. Löschen ist wiederherstellbar (`restorableUntil`).
// Beim Praxistest prüfen: Produktcodes des gebuchten Pakets, `bundleId` für inkludierte
// Postfächer, Passwortregeln, `forwarderType` bei Weiterleitungen.

extension HostingDeAdapter {
    static let defaultMailboxProduct = "email-imap-mailbox-12m"
    static let defaultForwarderProduct = "email-forwarder-external-12m"
    static let defaultCatchallProduct = "email-catchall-12m"
    static let defaultMailingListProduct = "email-mailinglist-team-v1-12m"
    static let defaultQuotaMB = 1024

    /// Felder, die hosting.de selbst pflegt und die nicht in `mailboxUpdate` gehören.
    static let mailboxReadOnly: Set<String> = ["accountId", "bundleId", "emailAddressUnicode", "domainName", "domainNameUnicode", "status",
                                               "storageQuotaUsed", "paidUntil", "renewOn", "deletionScheduledFor", "restorableUntil",
                                               "addDate", "lastChangeDate", "smtpForwarderTarget"]

    func productCode(_ extra: Extra, setting: String, fallback: String) -> String {
        if let code = extra["product_code"]?.stringValue, !code.isEmpty { return code }
        if let code = connection.settings[setting], !code.isEmpty { return code }
        return fallback
    }

    /// Mailbox-Objekt zu einer Adresse, optional auf Typen eingeschränkt.
    func mailboxObject(address: String, types: [String] = []) async throws -> JSONValue? {
        let a = Self.normalized(address)
        var parts: [HostingDeFilter] = [.or([.equal("MailboxEmailAddress", a), .equal("MailboxEmailAddressUnicode", a)])]
        if types.count == 1 { parts.append(.equal("MailboxType", types[0])) }
        else if types.count > 1 { parts.append(.or(types.map { .equal("MailboxType", $0) })) }
        return try await client.findPage("email", "mailboxesFind", filter: .and(parts), limit: 1).data.first
    }

    func mailboxObjects(domain: String?, types: [String]) async throws -> [JSONValue] {
        var parts: [HostingDeFilter] = [types.count == 1 ? .equal("MailboxType", types[0]) : .or(types.map { .equal("MailboxType", $0) })]
        if let domain {
            let d = Self.normalized(domain)
            parts.append(.or([.equal("MailboxDomainName", d), .equal("MailboxDomainNameUnicode", d)]))
        }
        return try await client.findAll("email", "mailboxesFind", filter: .and(parts))
    }

    /// Schreibt ein Mailbox-Objekt zurück und wartet, bis es wieder `active` ist.
    func writeMailbox(_ method: String, _ object: [String: JSONValue], password: String? = nil, what: String) async throws -> JSONValue {
        var clean = object
        for key in Self.mailboxReadOnly { clean.removeValue(forKey: key) }
        if method == "mailboxCreate" { clean.removeValue(forKey: "id") }
        var params: [String: JSONValue] = ["mailbox": .object(clean)]
        if let password { params["password"] = .string(password) }
        let result = try await client.call("email", method, params)
        var current = result.response
        if result.pending || current.string("status") != "active", let id = current.string("id") ?? object["id"]?.stringValue {
            current = try await waitForMailbox(id, what: what)
        }
        return current
    }

    func waitForMailbox(_ id: String, what: String) async throws -> JSONValue {
        let client = self.client
        return try await client.waitUntilActive(what) {
            try await client.findPage("email", "mailboxesFind", filter: .equal("MailboxId", id), limit: 1).data.first
        }
    }

    func mailboxExtra(_ item: JSONValue) -> Extra {
        var extra = Self.extra(from: item, keys: ["id", "type", "productCode", "bundleId", "isAdmin", "paidUntil", "renewOn",
                                                   "restorableUntil", "deletionScheduledFor", "emailAddressUnicode", "lastChangeDate"])
        if let spam = item["spamFilter"], spam != .null { extra["spam_filter_settings"] = spam }
        if let responder = item["autoResponder"], responder != .null { extra["auto_responder"] = responder }
        return extra
    }
}

// MARK: - Postfächer

extension HostingDeAdapter: MailboxAdapter {
    func mailbox(_ item: JSONValue) -> Mailbox {
        let spam = item["spamFilter"]
        let spamFilter: String? = spam.map { ($0.bool("spamChecks") ?? false) ? ($0.string("spamLevel") ?? "on") : "off" }
        return Mailbox(ref: ref(item.string("id") ?? ""), address: item.string("emailAddress") ?? "",
                       quotaMB: item.int("storageQuota"), usedMB: item.int("storageQuotaUsed"), status: item.string("status"),
                       spamFilter: spamFilter, senderAliases: [], copyTo: item.strings("forwarderTargets"), extra: mailboxExtra(item))
    }

    public func listMailboxes(domain: String?) async throws -> [Mailbox] {
        try await mailboxObjects(domain: domain, types: ["ImapMailbox"]).map { mailbox($0) }.sorted { $0.address < $1.address }
    }

    public func getMailbox(address: String) async throws -> Mailbox? {
        try await mailboxObject(address: address, types: ["ImapMailbox"]).map { mailbox($0) }
    }

    public func createMailbox(_ spec: MailboxSpec) async throws -> Mailbox {
        guard let password = spec.password, !password.isEmpty else {
            throw KastellanError.invalidArgument("hosting.de: ein IMAP-Postfach braucht ein Passwort")
        }
        var object: [String: JSONValue] = [
            "type": .string("ImapMailbox"),
            "productCode": .string(productCode(spec.extra, setting: "mailbox_product", fallback: Self.defaultMailboxProduct)),
            "emailAddress": .string(Self.normalized(spec.address)),
            "storageQuota": .int(spec.quotaMB ?? Self.defaultQuotaMB),
            "isAdmin": spec.extra["is_admin"] ?? .bool(false),
        ]
        if let copy = spec.copyTo, !copy.isEmpty { object["forwarderTargets"] = .array(copy.map { .string($0) }) }
        if let spam = spec.extra["spam_filter_settings"] { object["spamFilter"] = spam }
        let created = try await writeMailbox("mailboxCreate", object, password: password, what: "Postfach \(spec.address)")
        return mailbox(created)
    }

    public func updateMailbox(_ spec: MailboxSpec) async throws -> Mailbox {
        guard let current = try await mailboxObject(address: spec.address, types: ["ImapMailbox"]), var object = current.objectValue else {
            throw KastellanError.notFound("Postfach \(spec.address) bei hosting.de")
        }
        if let quota = spec.quotaMB { object["storageQuota"] = .int(quota) }
        if let copy = spec.copyTo { object["forwarderTargets"] = .array(copy.map { .string($0) }) }
        if let admin = spec.extra["is_admin"] { object["isAdmin"] = admin }
        if let spam = spec.extra["spam_filter_settings"] { object["spamFilter"] = spam }
        if let code = spec.extra["product_code"] { object["productCode"] = code }
        let updated = try await writeMailbox("mailboxUpdate", object, password: spec.password, what: "Postfach \(spec.address)")
        return mailbox(updated)
    }

    public func setMailboxPassword(address: String, password: String) async throws {
        guard let current = try await mailboxObject(address: address, types: ["ImapMailbox"]), let object = current.objectValue else {
            throw KastellanError.notFound("Postfach \(address) bei hosting.de")
        }
        _ = try await writeMailbox("mailboxUpdate", object, password: password, what: "Postfach \(address)")
    }

    public func deleteMailbox(address: String) async throws {
        guard let current = try await mailboxObject(address: address, types: ["ImapMailbox"]), let id = current.string("id") else {
            throw KastellanError.notFound("Postfach \(address) bei hosting.de")
        }
        try await client.call("email", "mailboxDelete", ["mailboxId": .string(id)])
    }
}

// MARK: - Weiterleitungen

extension HostingDeAdapter: MailForwardAdapter {
    static let forwardTypes = ["Forwarder", "Catchall"]

    func forward(_ item: JSONValue) -> MailForward {
        let targets = item["type"]?.stringValue == "Catchall" ? [item.string("forwarderTarget") ?? ""] : item.strings("forwarderTargets")
        let keepCopy = item.string("type") == "ImapMailbox"
        let status: MailForward.Status = (item.string("status") ?? "active") == "active" ? .active : .disabled
        var extra = mailboxExtra(item)
        if let t = item.string("forwarderType") { extra["forwarderType"] = .string(t) }
        return MailForward(ref: ref(item.string("id") ?? ""), address: item.string("emailAddress") ?? "", targets: targets,
                           keepCopy: keepCopy, status: status, extra: extra)
    }

    public func listForwards(domain: String?) async throws -> [MailForward] {
        try await mailboxObjects(domain: domain, types: Self.forwardTypes).map { forward($0) }.sorted { $0.address < $1.address }
    }

    public func createForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        let a = Self.normalized(address)
        guard !targets.isEmpty else { throw KastellanError.invalidArgument("Weiterleitung \(address) braucht mindestens ein Ziel") }
        if keepCopy {
            // Kopie behalten gibt es nur als Weiterleitung eines bestehenden IMAP-Postfachs.
            guard let current = try await mailboxObject(address: a, types: ["ImapMailbox"]), var object = current.objectValue else {
                throw KastellanError.invalidArgument("hosting.de: Kopie behalten geht nur für ein bestehendes Postfach; \(address) ist keins. Ohne keep_copy wird eine reine Weiterleitung angelegt.")
            }
            object["forwarderTargets"] = .array(targets.map { .string($0) })
            return forward(try await writeMailbox("mailboxUpdate", object, what: "Postfach \(address)"))
        }
        var object: [String: JSONValue] = ["emailAddress": .string(a)]
        if a.hasPrefix("*@") {
            object["type"] = .string("Catchall")
            object["productCode"] = .string(productCode([:], setting: "catchall_product", fallback: Self.defaultCatchallProduct))
            object["forwarderTarget"] = .string(targets[0])
        } else {
            object["type"] = .string("Forwarder")
            object["productCode"] = .string(productCode([:], setting: "forwarder_product", fallback: Self.defaultForwarderProduct))
            object["forwarderTargets"] = .array(targets.map { .string($0) })
            object["forwarderType"] = .string(Self.forwarderType(address: a, targets: targets))
        }
        return forward(try await writeMailbox("mailboxCreate", object, what: "Weiterleitung \(address)"))
    }

    public func updateForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        let types = keepCopy ? ["ImapMailbox"] : Self.forwardTypes
        guard let current = try await mailboxObject(address: address, types: types), var object = current.objectValue else {
            throw KastellanError.notFound("Weiterleitung \(address) bei hosting.de")
        }
        if current.string("type") == "Catchall" {
            object["forwarderTarget"] = .string(targets.first ?? "")
        } else {
            object["forwarderTargets"] = .array(targets.map { .string($0) })
            if current.string("type") == "Forwarder" {
                object["forwarderType"] = .string(Self.forwarderType(address: address, targets: targets))
            }
        }
        return forward(try await writeMailbox("mailboxUpdate", object, what: "Weiterleitung \(address)"))
    }

    public func deleteForward(address: String) async throws {
        if let current = try await mailboxObject(address: address, types: Self.forwardTypes), let id = current.string("id") {
            try await client.call("email", "mailboxDelete", ["mailboxId": .string(id)])
            return
        }
        // Weiterleitung eines Postfachs (Kopie behalten): nur die Ziele leeren.
        if let current = try await mailboxObject(address: address, types: ["ImapMailbox"]), var object = current.objectValue,
           !current.strings("forwarderTargets").isEmpty {
            object["forwarderTargets"] = .array([])
            _ = try await writeMailbox("mailboxUpdate", object, what: "Postfach \(address)")
            return
        }
        throw KastellanError.notFound("Weiterleitung \(address) bei hosting.de")
    }

    /// `internalForwarder`, wenn alle Ziele in derselben Domain liegen, sonst `externalForwarder`.
    static func forwarderType(address: String, targets: [String]) -> String {
        let domain = address.split(separator: "@").last.map(String.init)?.lowercased()
        let allInternal = targets.allSatisfy { $0.split(separator: "@").last.map(String.init)?.lowercased() == domain }
        return allInternal ? "internalForwarder" : "externalForwarder"
    }
}

// MARK: - Autoresponder

extension HostingDeAdapter: MailAutoresponderAdapter {
    func autoresponder(address: String, item: JSONValue) -> MailAutoresponder? {
        guard let r = item["autoResponder"], r != .null else { return nil }
        let active = (r.bool("active") ?? false) && (r.bool("enabled") ?? true)
        return MailAutoresponder(ref: ref(item.string("id") ?? ""), address: address, active: active, subject: r.string("subject"),
                                 text: r.string("body") ?? "", from: HostingDeDates.date(r.string("start")), until: HostingDeDates.date(r.string("end")))
    }

    public func getAutoresponder(address: String) async throws -> MailAutoresponder? {
        guard let current = try await mailboxObject(address: address, types: ["ImapMailbox"]) else {
            throw KastellanError.notFound("Postfach \(address) bei hosting.de")
        }
        return autoresponder(address: address, item: current)
    }

    public func setAutoresponder(_ responder: MailAutoresponder) async throws -> MailAutoresponder {
        guard let current = try await mailboxObject(address: responder.address, types: ["ImapMailbox"]), var object = current.objectValue else {
            throw KastellanError.notFound("Postfach \(responder.address) bei hosting.de")
        }
        object["autoResponder"] = JSONValue.compactObject([
            "subject": responder.subject.map { .string($0) },
            "body": .string(responder.text),
            "start": responder.from.map { .string(HostingDeDates.string($0)) },
            "end": responder.until.map { .string(HostingDeDates.string($0)) },
            "active": .bool(responder.active),
            "enabled": .bool(true),
        ])
        let updated = try await writeMailbox("mailboxUpdate", object, what: "Postfach \(responder.address)")
        return autoresponder(address: responder.address, item: updated)
            ?? MailAutoresponder(ref: ref(updated.string("id") ?? ""), address: responder.address, active: responder.active, subject: responder.subject, text: responder.text)
    }

    public func clearAutoresponder(address: String) async throws {
        guard let current = try await mailboxObject(address: address, types: ["ImapMailbox"]), var object = current.objectValue else {
            throw KastellanError.notFound("Postfach \(address) bei hosting.de")
        }
        var responder = current["autoResponder"]?.objectValue ?? [:]
        responder["active"] = .bool(false)
        responder["enabled"] = .bool(false)
        object["autoResponder"] = .object(responder)
        _ = try await writeMailbox("mailboxUpdate", object, what: "Postfach \(address)")
    }
}

// MARK: - Mailinglisten

extension HostingDeAdapter: MailingListAdapter {
    func mailingList(_ item: JSONValue) -> MailingList {
        var extra = mailboxExtra(item)
        for key in ["name", "accessMode", "replyToMode", "subjectPrefix", "digestSize"] {
            if let v = item[key], v != .null { extra[key] = v }
        }
        extra["owners"] = .array(item.strings("owners").map { .string($0) })
        return MailingList(ref: ref(item.string("id") ?? ""), address: item.string("emailAddress") ?? "",
                           members: item.strings("members"), moderated: item.string("accessMode") == "owners", extra: extra)
    }

    public func listMailingLists(domain: String?) async throws -> [MailingList] {
        try await mailboxObjects(domain: domain, types: ["MailingList"]).map { mailingList($0) }.sorted { $0.address < $1.address }
    }

    public func createMailingList(address: String, members: [String], extra: Extra) async throws -> MailingList {
        let a = Self.normalized(address)
        let owners = (extra["owners"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !owners.isEmpty else {
            throw KastellanError.invalidArgument("hosting.de: eine Mailingliste braucht mindestens einen Eigentümer (extra.owners)")
        }
        let object: [String: JSONValue] = [
            "type": .string("MailingList"),
            "productCode": .string(productCode(extra, setting: "mailinglist_product", fallback: Self.defaultMailingListProduct)),
            "emailAddress": .string(a),
            "name": extra["name"] ?? .string(String(a.split(separator: "@").first ?? "")),
            "accessMode": extra["access_mode"] ?? .string("members"),
            "replyToMode": extra["reply_to_mode"] ?? .string("list"),
            "owners": .array(owners.map { .string($0) }),
            "members": .array(members.map { .string($0) }),
        ]
        return mailingList(try await writeMailbox("mailboxCreate", object, what: "Mailingliste \(address)"))
    }

    public func updateMailingList(address: String, members: [String], extra: Extra) async throws -> MailingList {
        guard let current = try await mailboxObject(address: address, types: ["MailingList"]), var object = current.objectValue else {
            throw KastellanError.notFound("Mailingliste \(address) bei hosting.de")
        }
        object["members"] = .array(members.map { .string($0) })
        if let owners = extra["owners"] { object["owners"] = owners }
        if let name = extra["name"] { object["name"] = name }
        if let mode = extra["access_mode"] { object["accessMode"] = mode }
        if let reply = extra["reply_to_mode"] { object["replyToMode"] = reply }
        return mailingList(try await writeMailbox("mailboxUpdate", object, what: "Mailingliste \(address)"))
    }

    public func deleteMailingList(address: String) async throws {
        guard let current = try await mailboxObject(address: address, types: ["MailingList"]), let id = current.string("id") else {
            throw KastellanError.notFound("Mailingliste \(address) bei hosting.de")
        }
        try await client.call("email", "mailboxDelete", ["mailboxId": .string(id)])
    }
}

enum HostingDeDates {
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

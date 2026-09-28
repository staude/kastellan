import Foundation

// E-Mail bei Hostinger (`/api/mail/v1`). Eine Order je Domain (`GET /orders`), darunter Postfächer
// (`local_part` + Passwort, kein Update außer Passwort), Forwarder (Postfach → Ziel, das Ziel
// bestätigt per Mail, `is_keep_copy_enabled`), Aliase (Adresse → Postfach), Catch-alls und
// Autoreplies (eine je Postfach). Kastellan bildet Weiterleitungen auf diese drei Formen ab:
// Quelle ist ein Postfach → Forwarder; `*@domain` → Catch-all; Quelle ohne Postfach mit genau
// einem Ziel-Postfach derselben Domain → Alias. Speichergrößen kommen in Kilobyte.

extension HostingerAdapter {
    struct MailOrder {
        let id: String
        let domain: String
        let status: String
    }

    func mailOrders(domain: String? = nil) async throws -> [MailOrder] {
        let d = domain.map { Self.normalized($0) }
        return try await client.list("/api/mail/v1/orders").compactMap { item -> MailOrder? in
            guard let id = item.string("id") else { return nil }
            let name = item["domain"]?.string("name") ?? item["domain"]?.stringValue ?? ""
            guard d == nil || name.lowercased() == d! else { return nil }
            return MailOrder(id: id, domain: name, status: item.string("status") ?? "")
        }
    }

    func mailOrder(for address: String) async throws -> MailOrder {
        let domain = String(address.split(separator: "@").last ?? "")
        guard let order = try await mailOrders(domain: domain).first else {
            throw KastellanError.notFound("Hostinger: keine E-Mail-Order für \(domain)")
        }
        return order
    }

    func mailboxObject(address: String) async throws -> (MailOrder, JSONValue)? {
        let order = try await mailOrder(for: address)
        let a = address.lowercased()
        guard let box = try await client.list("/api/mail/v1/orders/\(order.id)/mailboxes").first(where: { $0.string("address")?.lowercased() == a }) else { return nil }
        return (order, box)
    }

    static func kbToMB(_ kb: Int?) -> Int? { kb.map { $0 / 1024 } }

    public func credentialService(for resource: ResourceType) -> CredentialService? {
        switch resource {
        case .mailbox: return CredentialService(host: connection.settings["mail_host"].flatMap { $0.isEmpty ? nil : $0 } ?? "imap.hostinger.com", scheme: "imaps", port: 993)
        default: return nil
        }
    }
}

extension HostingerAdapter: MailboxAdapter {
    func mailbox(_ item: JSONValue, order: MailOrder) -> Mailbox {
        var extra = Self.extra(from: item, keys: ["status", "status_reason", "protocols", "counts", "is_catchall", "created_at"])
        extra["order_id"] = .string(order.id)
        return Mailbox(ref: ref(item.string("id") ?? ""), address: item.string("address") ?? "",
                       quotaMB: Self.kbToMB(item["usage"]?.int("storage_quota")), usedMB: Self.kbToMB(item["usage"]?.int("storage_used")),
                       status: item.string("status"), spamFilter: nil, senderAliases: [], copyTo: [], extra: extra)
    }

    public func listMailboxes(domain: String?) async throws -> [Mailbox] {
        var out: [Mailbox] = []
        for order in try await mailOrders(domain: domain) {
            out += try await client.list("/api/mail/v1/orders/\(order.id)/mailboxes").map { mailbox($0, order: order) }
        }
        return out.sorted { $0.address < $1.address }
    }

    public func getMailbox(address: String) async throws -> Mailbox? {
        guard let (order, box) = try await mailboxObject(address: address) else { return nil }
        return mailbox(box, order: order)
    }

    public func createMailbox(_ spec: MailboxSpec) async throws -> Mailbox {
        guard let password = spec.password, !password.isEmpty else { throw KastellanError.invalidArgument("Hostinger: ein Postfach braucht ein Passwort (mindestens 8 Zeichen, Groß- und Kleinbuchstaben, Zahl, Sonderzeichen)") }
        let order = try await mailOrder(for: spec.address)
        let local = String(spec.address.split(separator: "@").first ?? "").lowercased()
        let created = try await client.post("/api/mail/v1/orders/\(order.id)/mailboxes", body: .object(["local_part": .string(local), "password": .string(password)]))
        var box = mailbox(created, order: order)
        if let copy = spec.copyTo, !copy.isEmpty, let id = created.string("id") {
            for target in copy {
                try await client.post("/api/mail/v1/mailboxes/\(id)/forwarders", body: .object(["destination": .string(target), "is_keep_copy_enabled": .bool(true)]))
            }
            box.copyTo = copy
            box.extra["note"] = .string("Weiterleitungen angelegt; jedes Ziel muss die Bestätigungsmail von Hostinger annehmen.")
        }
        if spec.quotaMB != nil { box.extra["quota_note"] = .string("Hostinger setzt die Postfachgröße über den Plan, quota_mb wurde ignoriert.") }
        return box
    }

    public func updateMailbox(_ spec: MailboxSpec) async throws -> Mailbox {
        guard let (order, current) = try await mailboxObject(address: spec.address), let id = current.string("id") else {
            throw KastellanError.notFound("Postfach \(spec.address) bei Hostinger")
        }
        if let password = spec.password, !password.isEmpty {
            try await client.patch("/api/mail/v1/mailboxes/\(id)/password", body: .object(["password": .string(password)]))
        }
        var box = mailbox(current, order: order)
        if let copy = spec.copyTo {
            let existing = try await client.list("/api/mail/v1/orders/\(order.id)/forwarders").filter { $0["mailbox"]?.string("id") == id }
            for fw in existing where !copy.contains(fw.string("destination") ?? "") {
                if let fid = fw.string("id") { try await client.delete("/api/mail/v1/forwarders/\(fid)") }
            }
            for target in copy where !existing.contains(where: { $0.string("destination") == target }) {
                try await client.post("/api/mail/v1/mailboxes/\(id)/forwarders", body: .object(["destination": .string(target), "is_keep_copy_enabled": .bool(true)]))
            }
            box.copyTo = copy
        }
        if spec.quotaMB != nil { box.extra["quota_note"] = .string("Hostinger setzt die Postfachgröße über den Plan, quota_mb wurde ignoriert.") }
        return box
    }

    public func setMailboxPassword(address: String, password: String) async throws {
        guard let (_, current) = try await mailboxObject(address: address), let id = current.string("id") else {
            throw KastellanError.notFound("Postfach \(address) bei Hostinger")
        }
        try await client.patch("/api/mail/v1/mailboxes/\(id)/password", body: .object(["password": .string(password)]))
    }

    public func deleteMailbox(address: String) async throws {
        guard let (_, current) = try await mailboxObject(address: address), let id = current.string("id") else {
            throw KastellanError.notFound("Postfach \(address) bei Hostinger")
        }
        try await client.delete("/api/mail/v1/mailboxes/\(id)")
    }
}

extension HostingerAdapter: MailForwardAdapter {
    func forwards(order: MailOrder) async throws -> [MailForward] {
        var out: [MailForward] = []
        // Forwarder: mehrere Ziele je Postfach werden zu einer Weiterleitung zusammengefasst.
        var byMailbox: [String: (address: String, targets: [String], keep: Bool, confirmed: Bool, ids: [String])] = [:]
        for fw in try await client.list("/api/mail/v1/orders/\(order.id)/forwarders") {
            let mbID = fw["mailbox"]?.string("id") ?? ""
            var entry = byMailbox[mbID] ?? (fw["mailbox"]?.string("address") ?? "", [], false, true, [])
            entry.targets.append(fw.string("destination") ?? "")
            entry.keep = entry.keep || (fw.bool("is_keep_copy_enabled") ?? false)
            entry.confirmed = entry.confirmed && (fw.bool("is_confirmed") ?? true)
            entry.ids.append(fw.string("id") ?? "")
            byMailbox[mbID] = entry
        }
        for (mbID, e) in byMailbox {
            out.append(MailForward(ref: ref("forwarder:\(mbID)"), address: e.address, targets: e.targets.sorted(), keepCopy: e.keep,
                                   status: e.confirmed ? .active : .pendingVerification, extra: ["kind": .string("forwarder"), "forwarder_ids": .array(e.ids.map { .string($0) }), "order_id": .string(order.id)]))
        }
        for alias in (try? await client.list("/api/mail/v1/orders/\(order.id)/aliases")) ?? [] {
            out.append(MailForward(ref: ref("alias:\(alias.string("id") ?? "")"), address: alias.string("address") ?? "",
                                   targets: [alias["mailbox"]?.string("address") ?? ""], keepCopy: false,
                                   status: alias.bool("is_active") == false ? .disabled : .active, extra: ["kind": .string("alias"), "order_id": .string(order.id)]))
        }
        for catchall in (try? await client.list("/api/mail/v1/orders/\(order.id)/catchalls")) ?? [] {
            out.append(MailForward(ref: ref("catchall:\(catchall.string("id") ?? "")"), address: "*@\(catchall.string("domain") ?? order.domain)",
                                   targets: [catchall["mailbox"]?.string("address") ?? ""], keepCopy: false,
                                   status: catchall.bool("is_confirmed") == false ? .pendingVerification : (catchall.bool("is_active") == false ? .disabled : .active),
                                   extra: ["kind": .string("catchall"), "order_id": .string(order.id)]))
        }
        return out
    }

    public func listForwards(domain: String?) async throws -> [MailForward] {
        var out: [MailForward] = []
        for order in try await mailOrders(domain: domain) { out += try await forwards(order: order) }
        return out.sorted { $0.address < $1.address }
    }

    public func createForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        guard !targets.isEmpty else { throw KastellanError.invalidArgument("Weiterleitung \(address) braucht mindestens ein Ziel") }
        let a = address.lowercased()
        let order = try await mailOrder(for: a)
        let boxes = try await client.list("/api/mail/v1/orders/\(order.id)/mailboxes")
        if a.hasPrefix("*@") {
            guard let target = boxes.first(where: { $0.string("address")?.lowercased() == targets[0].lowercased() }), let id = target.string("id") else {
                throw KastellanError.invalidArgument("Hostinger: Catch-all braucht als Ziel ein Postfach derselben Domain")
            }
            let created = try await client.post("/api/mail/v1/mailboxes/\(id)/catchalls")
            return MailForward(ref: ref("catchall:\(created.string("id") ?? "")"), address: a, targets: [targets[0]], keepCopy: false,
                               status: created.bool("is_confirmed") == false ? .pendingVerification : .active, extra: ["kind": .string("catchall"), "order_id": .string(order.id)])
        }
        if let box = boxes.first(where: { $0.string("address")?.lowercased() == a }), let id = box.string("id") {
            var ids: [String] = []
            var confirmed = true
            for target in targets {
                let fw = try await client.post("/api/mail/v1/mailboxes/\(id)/forwarders", body: .object(["destination": .string(target), "is_keep_copy_enabled": .bool(keepCopy)]))
                ids.append(fw.string("id") ?? "")
                confirmed = confirmed && (fw.bool("is_confirmed") ?? false)
            }
            return MailForward(ref: ref("forwarder:\(id)"), address: a, targets: targets, keepCopy: keepCopy, status: confirmed ? .active : .pendingVerification,
                               extra: ["kind": .string("forwarder"), "forwarder_ids": .array(ids.map { .string($0) }), "order_id": .string(order.id),
                                       "note": .string("Jedes Ziel muss die Bestätigungsmail von Hostinger annehmen, vorher ist die Weiterleitung inaktiv.")])
        }
        guard targets.count == 1, let target = boxes.first(where: { $0.string("address")?.lowercased() == targets[0].lowercased() }), let id = target.string("id") else {
            throw KastellanError.invalidArgument("Hostinger: \(address) ist kein Postfach. Ohne Postfach geht nur ein Alias auf genau ein Postfach derselben Domain; für externe Ziele erst ein Postfach anlegen.")
        }
        let local = String(a.split(separator: "@").first ?? "")
        let alias = try await client.post("/api/mail/v1/mailboxes/\(id)/aliases", body: .object(["local_part": .string(local)]))
        return MailForward(ref: ref("alias:\(alias.string("id") ?? "")"), address: a, targets: [targets[0]], keepCopy: false, status: .active,
                           extra: ["kind": .string("alias"), "order_id": .string(order.id)])
    }

    public func updateForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        try await deleteForward(address: address)
        return try await createForward(address: address, targets: targets, keepCopy: keepCopy)
    }

    public func deleteForward(address: String) async throws {
        let a = address.lowercased()
        let order = try await mailOrder(for: a)
        let all = try await forwards(order: order)
        guard let existing = all.first(where: { $0.address.lowercased() == a }) else {
            throw KastellanError.notFound("Weiterleitung \(address) bei Hostinger")
        }
        switch existing.extra["kind"]?.stringValue {
        case "forwarder":
            for id in existing.extra["forwarder_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                try await client.delete("/api/mail/v1/forwarders/\(id)")
            }
        case "alias":
            try await client.delete("/api/mail/v1/aliases/\(existing.ref.providerRef.dropFirst("alias:".count))")
        default:
            try await client.delete("/api/mail/v1/catchalls/\(existing.ref.providerRef.dropFirst("catchall:".count))")
        }
    }
}

extension HostingerAdapter: MailAutoresponderAdapter {
    func autoreply(address: String, item: JSONValue) -> MailAutoresponder {
        let ends = HostingerDates.date(item.string("ends_at"))
        let active = ends.map { $0 > Date() } ?? true
        return MailAutoresponder(ref: ref(item.string("id") ?? ""), address: address, active: active, subject: item.string("subject"),
                                 text: item.string("body") ?? "", from: HostingerDates.date(item.string("starts_at")), until: ends,
                                 extra: ["display_name": item["display_name"] ?? .null].filter { $0.value != .null })
    }

    func autoreplyObject(address: String) async throws -> (MailOrder, JSONValue)? {
        let order = try await mailOrder(for: address)
        let a = address.lowercased()
        guard let item = try await client.list("/api/mail/v1/orders/\(order.id)/autoreplies").first(where: { $0["mailbox"]?.string("address")?.lowercased() == a }) else { return nil }
        return (order, item)
    }

    public func getAutoresponder(address: String) async throws -> MailAutoresponder? {
        guard let (_, item) = try await autoreplyObject(address: address) else { return nil }
        return autoreply(address: address, item: item)
    }

    public func setAutoresponder(_ responder: MailAutoresponder) async throws -> MailAutoresponder {
        let body = JSONValue.compactObject([
            "subject": .string(responder.subject ?? "Abwesenheitsnotiz"),
            "body": .string(responder.text),
            "display_name": responder.extra["display_name"],
            "starts_at": responder.from.map { .string(MittwaldDates.string($0)) },
            "ends_at": responder.until.map { .string(MittwaldDates.string($0)) } ?? (responder.active ? nil : .string(MittwaldDates.string(Date()))),
        ])
        if let (_, existing) = try await autoreplyObject(address: responder.address), let id = existing.string("id") {
            return autoreply(address: responder.address, item: try await client.put("/api/mail/v1/autoreplies/\(id)", body: body))
        }
        guard let (_, box) = try await mailboxObject(address: responder.address), let id = box.string("id") else {
            throw KastellanError.notFound("Postfach \(responder.address) bei Hostinger")
        }
        return autoreply(address: responder.address, item: try await client.post("/api/mail/v1/mailboxes/\(id)/autoreplies", body: body))
    }

    public func clearAutoresponder(address: String) async throws {
        guard let (_, existing) = try await autoreplyObject(address: address), let id = existing.string("id") else { return }
        try await client.delete("/api/mail/v1/autoreplies/\(id)")
    }
}

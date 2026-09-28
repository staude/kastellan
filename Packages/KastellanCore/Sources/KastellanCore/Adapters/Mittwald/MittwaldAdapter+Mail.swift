import Foundation

// Schreibende Mail-Operationen bei Mittwald. Eine Entität `MailAddress`: Postfach (`mailbox`),
// reine Weiterleitung (`forwardAddresses` ohne `mailbox`) oder beides. Anlegen über
// `POST /projects/{id}/mail-addresses` (liefert nur `{id}`), Änderungen über PATCH-Teilrouten
// (`/password`, `/quota`, `/forward-addresses`, `/catch-all`, `/spam-protection`,
// `/autoresponder`), die 204 liefern. Danach wird das Objekt mit `if-event-reached` nachgelesen.
// Quota mindestens 200 MiB oder -1 (unbegrenzt). Passwörter sind nie lesbar.

extension MittwaldAdapter {
    static let minimumQuotaBytes = 209_715_200
    static let defaultQuotaBytes = 1_073_741_824

    static func quotaBytes(_ mb: Int?) -> Int {
        guard let mb else { return defaultQuotaBytes }
        if mb < 0 { return -1 }
        return max(mb * 1_048_576, minimumQuotaBytes)
    }

    /// Mailadresse nach dem Schreiben neu lesen (der Client schickt `if-event-reached`).
    func reloadMailAddress(id: String) async throws -> JSONValue {
        try await client.get("/mail-addresses/\(id)")
    }

    public func credentialService(for resource: ResourceType) -> CredentialService? {
        switch resource {
        case .mailbox: return CredentialService(host: connection.settings["mail_host"].flatMap { $0.isEmpty ? nil : $0 } ?? "mail.agenturserver.de", scheme: "imaps", port: 993)
        default: return nil
        }
    }
}

extension MittwaldAdapter {
    // MARK: Postfächer

    public func createMailbox(_ spec: MailboxSpec) async throws -> Mailbox {
        guard let password = spec.password, !password.isEmpty else {
            throw KastellanError.invalidArgument("Mittwald: ein Postfach braucht ein Passwort")
        }
        let project = try await projectID(spec.extra)
        var body: [String: JSONValue] = [
            "address": .string(spec.address.lowercased()),
            "isCatchAll": spec.extra["catch_all"] ?? .bool(false),
            "mailbox": .object([
                "password": .string(password),
                "quotaInBytes": .int(Self.quotaBytes(spec.quotaMB)),
                "enableSpamProtection": spec.extra["spam_protection"] ?? .bool(true),
            ]),
        ]
        if let copy = spec.copyTo, !copy.isEmpty { body["forwardAddresses"] = .array(copy.map { .string($0) }) }
        let created = try await client.post("/projects/\(project)/mail-addresses", body: .object(body))
        guard let id = created.string("id") else { throw KastellanError.provider("Mittwald: Antwort ohne Mailadressen-ID") }
        return mailbox(try await reloadMailAddress(id: id))
    }

    public func updateMailbox(_ spec: MailboxSpec) async throws -> Mailbox {
        let current = try await mailAddress(spec.address)
        guard let id = current.string("id"), current["mailbox"] != nil, current["mailbox"] != .null else {
            throw KastellanError.notFound("Postfach \(spec.address) bei Mittwald")
        }
        if let quota = spec.quotaMB {
            try await client.patch("/mail-addresses/\(id)/quota", body: .object(["quotaInBytes": .int(Self.quotaBytes(quota))]))
        }
        if let copy = spec.copyTo {
            try await client.patch("/mail-addresses/\(id)/forward-addresses", body: .object(["forwardAddresses": .array(copy.map { .string($0) })]))
        }
        if let catchAll = spec.extra["catch_all"]?.boolValue {
            try await client.patch("/mail-addresses/\(id)/catch-all", body: .object(["active": .bool(catchAll)]))
        }
        if let spam = spec.extra["spam_protection"] {
            let settings: JSONValue
            if let active = spam.boolValue {
                var existing = current["mailbox"]?["spamProtection"]?.objectValue ?? ["folder": .string("spam"), "relocationMinSpamScore": .int(5), "autoDeleteSpam": .bool(false)]
                existing["active"] = .bool(active)
                settings = .object(existing)
            } else {
                settings = spam
            }
            try await client.patch("/mail-addresses/\(id)/spam-protection", body: .object(["spamProtection": settings]))
        }
        if let password = spec.password, !password.isEmpty {
            try await client.patch("/mail-addresses/\(id)/password", body: .object(["password": .string(password)]))
        }
        return mailbox(try await reloadMailAddress(id: id))
    }

    public func setMailboxPassword(address: String, password: String) async throws {
        let current = try await mailAddress(address)
        guard let id = current.string("id"), current["mailbox"] != nil, current["mailbox"] != .null else {
            throw KastellanError.notFound("Postfach \(address) bei Mittwald")
        }
        try await client.patch("/mail-addresses/\(id)/password", body: .object(["password": .string(password)]))
    }

    public func deleteMailbox(address: String) async throws {
        let current = try await mailAddress(address)
        guard let id = current.string("id") else { throw KastellanError.notFound("Postfach \(address) bei Mittwald") }
        try await client.delete("/mail-addresses/\(id)")
    }

    // MARK: Weiterleitungen

    public func createForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        guard !targets.isEmpty else { throw KastellanError.invalidArgument("Weiterleitung \(address) braucht mindestens ein Ziel") }
        let a = address.lowercased()
        if let existing = try? await mailAddress(a), let id = existing.string("id") {
            // Adresse gibt es schon: Ziele setzen. Bei Postfach bleibt die Kopie im Postfach.
            if !keepCopy, existing["mailbox"] != nil, existing["mailbox"] != .null {
                throw KastellanError.invalidArgument("Mittwald: \(address) ist ein Postfach; ohne keep_copy bitte das Postfach löschen oder keep_copy=true setzen")
            }
            try await client.patch("/mail-addresses/\(id)/forward-addresses", body: .object(["forwardAddresses": .array(targets.map { .string($0) })]))
            return forward(try await reloadMailAddress(id: id))
        }
        if keepCopy {
            throw KastellanError.invalidArgument("Mittwald: keep_copy geht nur für ein bestehendes Postfach; \(address) gibt es nicht")
        }
        let project = try await projectID()
        let created = try await client.post("/projects/\(project)/mail-addresses", body: .object([
            "address": .string(a), "forwardAddresses": .array(targets.map { .string($0) }),
        ]))
        guard let id = created.string("id") else { throw KastellanError.provider("Mittwald: Antwort ohne Mailadressen-ID") }
        return forward(try await reloadMailAddress(id: id))
    }

    public func updateForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        let current = try await mailAddress(address)
        guard let id = current.string("id") else { throw KastellanError.notFound("Weiterleitung \(address) bei Mittwald") }
        try await client.patch("/mail-addresses/\(id)/forward-addresses", body: .object(["forwardAddresses": .array(targets.map { .string($0) })]))
        return forward(try await reloadMailAddress(id: id))
    }

    public func deleteForward(address: String) async throws {
        let current = try await mailAddress(address)
        guard let id = current.string("id") else { throw KastellanError.notFound("Weiterleitung \(address) bei Mittwald") }
        if current["mailbox"] != nil, current["mailbox"] != .null {
            // Postfach bleibt, nur die Weiterleitung entfällt.
            try await client.patch("/mail-addresses/\(id)/forward-addresses", body: .object(["forwardAddresses": .array([])]))
        } else {
            try await client.delete("/mail-addresses/\(id)")
        }
    }

    // MARK: Autoresponder

    public func setAutoresponder(_ responder: MailAutoresponder) async throws -> MailAutoresponder {
        let current = try await mailAddress(responder.address)
        guard let id = current.string("id") else { throw KastellanError.notFound("Postfach \(responder.address) bei Mittwald") }
        let text = responder.subject.map { "\($0)\n\n\(responder.text)" } ?? responder.text
        let body = JSONValue.compactObject([
            "active": .bool(responder.active),
            "message": .string(text),
            "startsAt": responder.from.map { .string(MittwaldDates.string($0)) },
            "expiresAt": responder.until.map { .string(MittwaldDates.string($0)) },
        ])
        try await client.patch("/mail-addresses/\(id)/autoresponder", body: .object(["autoResponder": body]))
        let reloaded = try await reloadMailAddress(id: id)
        return autoresponder(address: responder.address, item: reloaded)
            ?? MailAutoresponder(ref: ref(id), address: responder.address, active: responder.active, subject: nil, text: text, from: responder.from, until: responder.until)
    }

    public func clearAutoresponder(address: String) async throws {
        let current = try await mailAddress(address)
        guard let id = current.string("id") else { throw KastellanError.notFound("Postfach \(address) bei Mittwald") }
        try await client.patch("/mail-addresses/\(id)/autoresponder", body: .object(["autoResponder": .null]))
    }
}

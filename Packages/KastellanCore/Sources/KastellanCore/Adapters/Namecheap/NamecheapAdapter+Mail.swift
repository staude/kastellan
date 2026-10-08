import Foundation

// Mail-Weiterleitungen bei Namecheap. `domains.dns.getEmailForwarding` liefert je Domain
// `<Forward mailbox="info">ziel@example.net</Forward>`, `setEmailForwarding` ersetzt die ganze
// Liste (`MailBoxN`, `ForwardToN`). Mehrere Ziele einer Adresse sind mehrere Einträge mit
// gleichem Postfachnamen, `*` ist der Catch-all. Weiterleitungen greifen nur, wenn die Zone auf
// `EmailType=FWD` steht; sonst gelten die MX-Records. Kastellan stellt das nicht selbst um, weil
// das eine MX-Änderung wäre. Eine Kopie behalten gibt es bei Namecheap nicht.

extension NamecheapAdapter: MailForwardAdapter {
    struct ForwardEntry: Equatable {
        var mailbox: String
        var target: String
    }

    func readForwards(_ domain: String) async throws -> [ForwardEntry] {
        let response = try await client.call("namecheap.domains.dns.getEmailForwarding", [("DomainName", domain)])
        return response.descendants("Forward").compactMap { f in
            let mailbox = (f["mailbox"] ?? f["MailBox"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let target = f.text.trimmingCharacters(in: .whitespaces)
            guard !mailbox.isEmpty, !target.isEmpty else { return nil }
            return ForwardEntry(mailbox: mailbox, target: target)
        }
    }

    func writeForwards(_ domain: String, _ entries: [ForwardEntry]) async throws {
        var params: [(String, String)] = [("DomainName", domain)]
        for (i, e) in entries.enumerated() {
            params += [("MailBox\(i + 1)", e.mailbox), ("ForwardTo\(i + 1)", e.target)]
        }
        try await client.call("namecheap.domains.dns.setEmailForwarding", params)
    }

    func forwards(_ domain: String, _ entries: [ForwardEntry], emailType: String?) -> [MailForward] {
        var order: [String] = []
        var targets: [String: [String]] = [:]
        for e in entries {
            if targets[e.mailbox] == nil { order.append(e.mailbox) }
            targets[e.mailbox, default: []].append(e.target)
        }
        let effective = emailType == nil || emailType == "FWD"
        return order.map { mailbox in
            var extra: Extra = [:]
            if mailbox == "*" { extra["catch_all"] = .bool(true) }
            if let emailType, emailType != "FWD" {
                extra["warning"] = .string("Die Domain steht auf E-Mail-Typ \(emailType), Weiterleitungen greifen erst mit FWD")
            }
            return MailForward(ref: ref("\(domain)/\(mailbox)"), address: "\(mailbox)@\(domain)", targets: targets[mailbox]!,
                               keepCopy: false, status: effective ? .active : .disabled, extra: extra)
        }
    }

    func emailType(_ domain: String) async throws -> String {
        try await readZone(domain).emailType
    }

    static func split(address: String) throws -> (mailbox: String, domain: String) {
        let parts = address.lowercased().trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else {
            throw KastellanError.invalidArgument("Namecheap: \(address) ist keine Mailadresse (für den Catch-all *@domain)")
        }
        return (String(parts[0]), normalized(String(parts[1])))
    }

    static func validTargets(_ targets: [String]) throws -> [String] {
        let cleaned = targets.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw KastellanError.invalidArgument("Mindestens ein Weiterleitungsziel angeben") }
        for t in cleaned where !t.contains("@") { throw KastellanError.invalidArgument("Weiterleitungsziel \(t) ist keine Mailadresse") }
        return cleaned
    }

    // MARK: - MailForwardAdapter

    /// Mit Domain: Weiterleitungen dieser Domain samt Status aus dem E-Mail-Typ. Ohne Domain: alle
    /// Domains mit Namecheap-DNS, ohne Status-Prüfung (spart je Domain einen Aufruf).
    public func listForwards(domain: String?) async throws -> [MailForward] {
        if let domain {
            let d = Self.normalized(domain)
            let type = try await emailType(d)
            return forwards(d, try await readForwards(d), emailType: type)
        }
        var out: [MailForward] = []
        for zone in try await listZones() {
            out += forwards(zone.zone, try await readForwards(zone.zone), emailType: nil)
        }
        return out
    }

    public func createForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        try await setForward(address: address, targets: targets, keepCopy: keepCopy, mustExist: false)
    }

    public func updateForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        try await setForward(address: address, targets: targets, keepCopy: keepCopy, mustExist: true)
    }

    public func deleteForward(address: String) async throws {
        let (mailbox, domain) = try Self.split(address: address)
        let entries = try await readForwards(domain)
        guard entries.contains(where: { $0.mailbox == mailbox }) else { throw KastellanError.notFound("Weiterleitung \(address) bei Namecheap") }
        try await writeForwards(domain, entries.filter { $0.mailbox != mailbox })
    }

    private func setForward(address: String, targets: [String], keepCopy: Bool, mustExist: Bool) async throws -> MailForward {
        guard !keepCopy else {
            throw KastellanError.unsupported("Namecheap: Weiterleitungen können keine Kopie behalten, es gibt dort keine Postfächer")
        }
        let (mailbox, domain) = try Self.split(address: address)
        let cleaned = try Self.validTargets(targets)
        let type = try await emailType(domain)
        guard type == "FWD" else {
            throw KastellanError.unsupported("Namecheap: \(domain) steht auf E-Mail-Typ \(type.isEmpty ? "keiner" : type). Weiterleitungen greifen nur mit „Email Forwarding“ (FWD). Das Umstellen ersetzt die MX-Records und geht nur im Namecheap-Panel unter Domain → Advanced DNS → Mail Settings.")
        }
        var entries = try await readForwards(domain)
        let exists = entries.contains { $0.mailbox == mailbox }
        if mustExist && !exists { throw KastellanError.notFound("Weiterleitung \(address) bei Namecheap") }
        if !mustExist && exists { throw KastellanError.invalidArgument("Weiterleitung \(address) existiert bereits, zum Ändern mail_forward_update verwenden") }
        if let at = entries.firstIndex(where: { $0.mailbox == mailbox }) {
            entries.removeAll { $0.mailbox == mailbox }
            entries.insert(contentsOf: cleaned.map { ForwardEntry(mailbox: mailbox, target: $0) }, at: min(at, entries.count))
        } else {
            entries += cleaned.map { ForwardEntry(mailbox: mailbox, target: $0) }
        }
        guard Set(entries.map(\.mailbox)).count <= 100 else { throw KastellanError.invalidArgument("Namecheap erlaubt höchstens 100 Weiterleitungen je Domain") }
        try await writeForwards(domain, entries)
        guard let result = forwards(domain, try await readForwards(domain), emailType: type).first(where: { $0.address == "\(mailbox)@\(domain)" }) else {
            throw KastellanError.notFound("Weiterleitung \(address) nach dem Speichern")
        }
        return result
    }
}

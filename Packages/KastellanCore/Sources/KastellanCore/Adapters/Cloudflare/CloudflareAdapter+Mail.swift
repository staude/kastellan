import Foundation

// Weiterleitungen über Cloudflare Email Routing (https://developers.cloudflare.com/api/resources/email_routing/):
// Regeln je Zone (`/zones/{zone_id}/email/routing/rules`, Catch-all unter `.../rules/catch_all`),
// Zieladressen auf Account-Ebene (`/accounts/{account_id}/email/routing/addresses`). Ein Ziel muss
// dort angelegt und vom Empfänger bestätigt sein; bis dahin meldet Kastellan `pending_verification`.
// Ohne `account_id` in der Verbindung lässt sich das nicht prüfen, der Status folgt dann `enabled`.
// Eine Kopie im Postfach (`keep_copy`) kennt Cloudflare nicht; der Wunsch wird nur in `extra` vermerkt.

extension CloudflareAdapter: MailForwardAdapter {
    /// Kastellan-Adresse des Catch-all einer Zone.
    static func catchAllAddress(zone: String) -> String { "*@" + zoneName(zone) }

    static func isCatchAll(_ address: String) -> Bool { address.hasPrefix("*@") }

    /// Lokalteil und Domain einer Adresse; `*` ist als Lokalteil erlaubt (Catch-all).
    static func split(address: String) throws -> (local: String, domain: String) {
        let parts = address.trimmingCharacters(in: .whitespaces).split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else {
            throw KastellanError.invalidArgument("Keine gültige Adresse: \(address)")
        }
        return (parts[0], zoneName(parts[1]))
    }

    static func cleanTargets(_ targets: [String]) throws -> [String] {
        let clean = targets.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { throw KastellanError.invalidArgument("Weiterleitung braucht mindestens ein Ziel") }
        return clean
    }

    // MARK: - Abbildung

    /// Bekannte Zieladressen des Accounts, kleingeschrieben; `nil`, wenn keine `account_id` gesetzt ist.
    struct Destinations {
        var known: Set<String>
        var verified: Set<String>

        init(_ addresses: [CloudflareEmailAddress]) {
            known = Set(addresses.map { $0.email.lowercased() })
            verified = Set(addresses.filter(\.isVerified).map { $0.email.lowercased() })
        }

        func status(for targets: [String], enabled: Bool) -> MailForward.Status {
            guard enabled else { return .disabled }
            return targets.allSatisfy { verified.contains($0.lowercased()) } ? .active : .pendingVerification
        }
    }

    func destinations() async throws -> Destinations? {
        guard let accountID else { return nil }
        let addresses: [CloudflareEmailAddress] = try await client.list("/accounts/\(accountID)/email/routing/addresses")
        return Destinations(addresses)
    }

    /// Regel → `MailForward`. Regeln ohne `forward`-Aktion (Worker, Drop) sind keine Weiterleitungen.
    func forward(from rule: CloudflareEmailRule, zone: String, destinations: Destinations?) -> MailForward? {
        let targets = rule.forwardTargets
        guard !targets.isEmpty else { return nil }
        let address: String
        if rule.isCatchAll {
            address = Self.catchAllAddress(zone: zone)
        } else if let literal = rule.literalAddress {
            address = literal.lowercased()
        } else {
            return nil
        }
        let enabled = rule.enabled ?? true
        let status: MailForward.Status
        if let destinations {
            status = destinations.status(for: targets, enabled: enabled)
        } else {
            status = enabled ? .active : .disabled
        }
        var extra: Extra = ["enabled": .bool(enabled), "catch_all": .bool(rule.isCatchAll)]
        if let id = rule.id { extra["rule_id"] = .string(id) }
        if let tag = rule.tag { extra["tag"] = .string(tag) }
        if let name = rule.name, !name.isEmpty { extra["name"] = .string(name) }
        if let priority = rule.priority { extra["priority"] = .int(priority) }
        if destinations == nil { extra["verification_unknown"] = .bool(true) }
        return MailForward(ref: ref(rule.id ?? address), address: address, targets: targets, keepCopy: false, status: status, extra: extra)
    }

    /// Body für `POST rules`, `PUT rules/{id}` und `PUT rules/catch_all`.
    static func ruleBody(address: String, targets: [String], enabled: Bool, name: String?, priority: Int?) -> JSONValue {
        let catchAll = isCatchAll(address)
        var body: [String: JSONValue] = [
            "name": .string(name ?? (catchAll ? "Kastellan: Catch-all" : "Kastellan: \(address)")),
            "enabled": .bool(enabled),
            "matchers": .array([catchAll
                ? .object(["type": .string("all")])
                : .object(["type": .string("literal"), "field": .string("to"), "value": .string(address)])]),
            "actions": .array([.object(["type": .string("forward"), "value": .array(targets.map(JSONValue.string))])]),
        ]
        if let priority, !catchAll { body["priority"] = .int(priority) }
        return .object(body)
    }

    /// Catch-all abschalten: Cloudflare kennt kein Löschen, nur `enabled: false` mit `drop`.
    static func catchAllOffBody(name: String?) -> JSONValue {
        .object([
            "name": .string(name ?? "Kastellan: Catch-all"),
            "enabled": .bool(false),
            "matchers": .array([.object(["type": .string("all")])]),
            "actions": .array([.object(["type": .string("drop")])]),
        ])
    }

    private static func noteKeepCopy(_ forward: MailForward, requested: Bool) -> MailForward {
        var f = forward
        if requested { f.extra["keep_copy_unsupported"] = .bool(true) }
        return f
    }

    // MARK: - Lesen

    func forwards(zone: String, destinations: Destinations?) async throws -> [MailForward] {
        let z = Self.zoneName(zone)
        let id = try await zoneID(z)
        let rules: [CloudflareEmailRule] = try await client.list("/zones/\(id)/email/routing/rules")
        var result = rules.compactMap { forward(from: $0, zone: z, destinations: destinations) }
        let catchAll: CloudflareEmailRule = try await client.get("/zones/\(id)/email/routing/rules/catch_all")
        if let f = forward(from: catchAll, zone: z, destinations: destinations) { result.append(f) }
        return result
    }

    public func listForwards(domain: String?) async throws -> [MailForward] {
        let destinations = try await destinations()
        if let domain, !domain.isEmpty {
            return try await forwards(zone: domain, destinations: destinations)
        }
        var all: [MailForward] = []
        for zone in try await listZones() {
            all.append(contentsOf: try await forwards(zone: zone.zone, destinations: destinations))
        }
        return all
    }

    func findRule(address: String, zoneID: String) async throws -> CloudflareEmailRule {
        let wanted = address.lowercased()
        let rules: [CloudflareEmailRule] = try await client.list("/zones/\(zoneID)/email/routing/rules")
        guard let rule = rules.first(where: { $0.literalAddress?.lowercased() == wanted }), rule.id != nil else {
            throw KastellanError.notFound("Weiterleitung \(address) bei Cloudflare")
        }
        return rule
    }

    // MARK: - Schreiben

    /// Legt fehlende Zieladressen auf dem Account an. Neue Adressen sind unbestätigt, bis der
    /// Empfänger den Link aus der Cloudflare-Mail klickt.
    func ensureDestinations(_ targets: [String], required: Bool) async throws -> Destinations? {
        guard let accountID else {
            if required {
                throw KastellanError.invalidArgument("Cloudflare braucht die Account-ID in der Verbindung (Einstellung account_id), um Zieladressen für Email Routing anzulegen")
            }
            return nil
        }
        var destinations = try await destinations() ?? Destinations([])
        for target in targets where !destinations.known.contains(target.lowercased()) {
            let created: CloudflareEmailAddress = try await client.post("/accounts/\(accountID)/email/routing/addresses", body: .object(["email": .string(target)]))
            destinations.known.insert(created.email.lowercased())
            if created.isVerified { destinations.verified.insert(created.email.lowercased()) }
        }
        return destinations
    }

    public func createForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        let (_, domain) = try Self.split(address: address)
        let targets = try Self.cleanTargets(targets)
        let destinations = try await ensureDestinations(targets, required: true)
        let id = try await zoneID(domain)
        let address = address.lowercased()
        let rule: CloudflareEmailRule
        if Self.isCatchAll(address) {
            rule = try await client.put("/zones/\(id)/email/routing/rules/catch_all",
                                        body: Self.ruleBody(address: address, targets: targets, enabled: true, name: nil, priority: nil))
        } else {
            rule = try await client.post("/zones/\(id)/email/routing/rules",
                                         body: Self.ruleBody(address: address, targets: targets, enabled: true, name: nil, priority: nil))
        }
        let mapped = forward(from: rule, zone: domain, destinations: destinations)
            ?? MailForward(ref: ref(rule.id ?? address), address: address, targets: targets,
                           status: destinations?.status(for: targets, enabled: true) ?? .active)
        return Self.noteKeepCopy(mapped, requested: keepCopy)
    }

    public func updateForward(address: String, targets: [String], keepCopy: Bool) async throws -> MailForward {
        let (_, domain) = try Self.split(address: address)
        let targets = try Self.cleanTargets(targets)
        let destinations = try await ensureDestinations(targets, required: false)
        let id = try await zoneID(domain)
        let address = address.lowercased()
        let rule: CloudflareEmailRule
        if Self.isCatchAll(address) {
            rule = try await client.put("/zones/\(id)/email/routing/rules/catch_all",
                                        body: Self.ruleBody(address: address, targets: targets, enabled: true, name: nil, priority: nil))
        } else {
            let current = try await findRule(address: address, zoneID: id)
            rule = try await client.put("/zones/\(id)/email/routing/rules/\(current.id!)",
                                        body: Self.ruleBody(address: address, targets: targets, enabled: current.enabled ?? true,
                                                            name: current.name, priority: current.priority))
        }
        let mapped = forward(from: rule, zone: domain, destinations: destinations)
            ?? MailForward(ref: ref(rule.id ?? address), address: address, targets: targets,
                           status: destinations?.status(for: targets, enabled: true) ?? .active)
        return Self.noteKeepCopy(mapped, requested: keepCopy)
    }

    public func deleteForward(address: String) async throws {
        let (_, domain) = try Self.split(address: address)
        let id = try await zoneID(domain)
        if Self.isCatchAll(address) {
            let current: CloudflareEmailRule = try await client.get("/zones/\(id)/email/routing/rules/catch_all")
            let _: CloudflareEmailRule = try await client.put("/zones/\(id)/email/routing/rules/catch_all", body: Self.catchAllOffBody(name: current.name))
            return
        }
        let current = try await findRule(address: address, zoneID: id)
        let _: CloudflareEmailRule = try await client.delete("/zones/\(id)/email/routing/rules/\(current.id!)")
    }
}

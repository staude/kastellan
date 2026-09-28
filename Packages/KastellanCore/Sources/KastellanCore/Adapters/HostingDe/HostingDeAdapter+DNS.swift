import Foundation

// DNS bei hosting.de: Zonen (`zoneConfigsFind`) und Records (`recordsFind`). Änderungen gibt es
// nur gebündelt über `recordsUpdate` mit `recordsToAdd`, `recordsToModify` und `recordsToDelete`;
// Kastellans `applyChanges` bildet direkt darauf ab, Einzeloperationen nutzen je eine Liste.
// Record-Namen sind bei hosting.de voll qualifiziert, Kastellan zeigt sie relativ zur Zone
// (`@` für den Apex). Nach einem Update ist die Zone kurz `blocked`; der Adapter wartet, bis
// sie wieder `active` ist, bevor er das Ergebnis liefert oder erneut schreibt.

extension HostingDeAdapter: DNSAdapter {
    public func listZones() async throws -> [DNSZone] {
        try await client.findAll("dns", "zoneConfigsFind").map { zone($0) }.sorted { $0.zone < $1.zone }
    }

    public func listRecords(zone: String) async throws -> [DNSRecord] {
        let config = try await zoneConfig(named: zone)
        let items = try await client.findAll("dns", "recordsFind", filter: .equal("ZoneConfigId", config.id))
        return items.map { record(zone: zone, item: $0) }.sorted { ($0.name, $0.type) < ($1.name, $1.type) }
    }

    public func createRecord(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let results = try await applyChanges(zone: zone, changes: [.create(name: name, type: type, content: content, ttl: ttl, priority: priority)])
        let fqdn = Self.fqdn(name, zone: zone)
        let expected = Self.content(content, type: type)
        guard let created = results.first(where: { Self.fqdn($0.name, zone: zone) == fqdn && $0.type == type.uppercased() && $0.content == expected }) else {
            throw KastellanError.notFound("DNS-Record \(name) \(type) in Zone \(zone) nach dem Anlegen")
        }
        return created
    }

    public func updateRecord(zone: String, providerRef: String, content: String?, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let results = try await applyChanges(zone: zone, changes: [.update(providerRef: providerRef, content: content, ttl: ttl, priority: priority)])
        guard let updated = results.first(where: { $0.ref.providerRef == providerRef }) else {
            throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone) nach der Änderung")
        }
        return updated
    }

    public func deleteRecord(zone: String, providerRef: String) async throws {
        _ = try await applyChanges(zone: zone, changes: [.delete(providerRef: providerRef)])
    }

    /// Alle Änderungen in einem `recordsUpdate`. Für `update` werden die vorhandenen Records
    /// gelesen, weil hosting.de den kompletten Record erwartet. Liefert den Stand der Zone
    /// nach der Änderung, sobald sie wieder `active` ist.
    public func applyChanges(zone: String, changes: [DNSChange]) async throws -> [DNSRecord] {
        let config = try await zoneConfig(named: zone)
        if config.status != "active" {
            _ = try await waitForZone(config.id, what: "Zone \(zone)")
        }

        var toAdd: [JSONValue] = []
        var toModify: [JSONValue] = []
        var toDelete: [JSONValue] = []
        let needsExisting = changes.contains { if case .update = $0 { true } else { false } }
        let existing = needsExisting ? try await listRecords(zone: zone) : []

        for change in changes {
            switch change {
            case .create(let name, let type, let content, let ttl, let priority):
                toAdd.append(JSONValue.compactObject([
                    "name": .string(Self.fqdn(name, zone: zone)),
                    "type": .string(type.uppercased()),
                    "content": .string(Self.content(content, type: type)),
                    "ttl": .int(max(ttl ?? Self.defaultTTL, Self.minimumTTL)),
                    "priority": priority.map { .int($0) },
                ]))
            case .update(let providerRef, let content, let ttl, let priority):
                guard let current = existing.first(where: { $0.ref.providerRef == providerRef }) else {
                    throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone)")
                }
                toModify.append(JSONValue.compactObject([
                    "id": .string(providerRef),
                    "name": .string(Self.fqdn(current.name, zone: zone)),
                    "type": .string(current.type),
                    "content": .string(content.map { Self.content($0, type: current.type) } ?? current.content),
                    "ttl": .int(max(ttl ?? current.ttl ?? Self.defaultTTL, Self.minimumTTL)),
                    "priority": (priority ?? current.priority).map { .int($0) },
                ]))
            case .delete(let providerRef):
                toDelete.append(.object(["id": .string(providerRef)]))
            }
        }

        var params: [String: JSONValue] = ["zoneConfigId": .string(config.id)]
        if !toAdd.isEmpty { params["recordsToAdd"] = .array(toAdd) }
        if !toModify.isEmpty { params["recordsToModify"] = .array(toModify) }
        if !toDelete.isEmpty { params["recordsToDelete"] = .array(toDelete) }
        let result = try await client.call("dns", "recordsUpdate", params)

        var records = result.response.array("records")
        if result.pending || result.response["zoneConfig"]?.string("status") != "active" {
            _ = try await waitForZone(config.id, what: "Zone \(zone)")
            records = try await client.findAll("dns", "recordsFind", filter: .equal("ZoneConfigId", config.id))
        }
        return records.map { record(zone: zone, item: $0) }
    }

    // MARK: - Mapping

    func zone(_ item: JSONValue) -> DNSZone {
        var extra = Self.extra(from: item, keys: ["nameUnicode", "type", "dnsSecMode", "status", "lastChangeDate", "emailAddress", "accountId"])
        if let template = item.string("templateValues") { extra["template"] = .string(template) }
        let ttl = item["soaValues"]?.int("ttl")
        return DNSZone(ref: ref(item.string("id") ?? ""), zone: item.string("name") ?? "", defaultTTL: ttl, extra: extra)
    }

    func record(zone: String, item: JSONValue) -> DNSRecord {
        let extra = Self.extra(from: item, keys: ["lastChangeDate", "recordTemplateId"])
        return DNSRecord(ref: ref(item.string("id") ?? ""), zone: zone,
                         name: Self.relativeName(item.string("name") ?? "", zone: zone),
                         type: item.string("type") ?? "", content: item.string("content") ?? "",
                         ttl: item.int("ttl"), priority: item.int("priority"), extra: extra)
    }

    // MARK: - Helfer

    struct ZoneConfig: Sendable {
        let id: String
        let name: String
        let status: String
    }

    /// Zonen-Konfiguration zu einem Namen (ACE oder Unicode), `notFound` wenn es sie nicht gibt.
    func zoneConfig(named zone: String) async throws -> ZoneConfig {
        let name = zone.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let filter = HostingDeFilter.or([.equal("ZoneName", name), .equal("ZoneNameUnicode", name)])
        let (data, _) = try await client.findPage("dns", "zoneConfigsFind", filter: filter, limit: 1)
        guard let item = data.first, let id = item.string("id") else {
            throw KastellanError.notFound("DNS-Zone \(zone) bei hosting.de")
        }
        return ZoneConfig(id: id, name: item.string("name") ?? name, status: item.string("status") ?? "")
    }

    /// Wartet, bis die Zone wieder `active` ist.
    @discardableResult
    func waitForZone(_ id: String, what: String) async throws -> JSONValue {
        let client = self.client
        return try await client.waitUntilActive(what) {
            try await client.findPage("dns", "zoneConfigsFind", filter: .equal("ZoneConfigId", id), limit: 1).data.first
        }
    }

    static let minimumTTL = 60
    static let defaultTTL = 3600

    /// Voll qualifizierter Name für hosting.de: `@`, leer oder der Zonenname selbst ergeben den Apex.
    static func fqdn(_ name: String, zone: String) -> String {
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        let z = zone.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if n.isEmpty || n == "@" || n == z { return z }
        if n.hasSuffix("." + z) { return n }
        return n + "." + z
    }

    /// Name relativ zur Zone, `@` für den Apex.
    static func relativeName(_ fqdn: String, zone: String) -> String {
        var n = fqdn.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        let z = zone.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if n.isEmpty || n == z { return "@" }
        if n.hasSuffix("." + z) { n.removeLast(z.count + 1) }
        return n
    }

    /// TXT-Inhalte müssen bei hosting.de in Anführungszeichen stehen.
    static func content(_ content: String, type: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard type.uppercased() == "TXT", !trimmed.hasPrefix("\"") else { return trimmed }
        return "\"" + trimmed.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

import Foundation

// DNS über die Hetzner Cloud API: Zonen (`/zones`) und RRSets (`/zones/{zone}/rrsets`).
// Hetzner fasst alle Werte gleichen Namens und Typs zu einem RRSet zusammen; Kastellan zeigt
// jeden Wert als eigenen `DNSRecord` mit `provider_ref` `<name>/<type>/<index>`. Damit der
// Index zwischen Auflisten und Ändern stabil bleibt (Hetzner garantiert keine Reihenfolge),
// werden die Werte eines RRSets immer nach Wert sortiert. Änderungen laufen über die
// RRSet-Actions `add_records`, `set_records`, `remove_records` und `change_ttl`.

extension HetznerAdapter: DNSAdapter {
    public func listZones() async throws -> [DNSZone] {
        try await client.list("/zones", key: "zones").map { zone($0) }
    }

    public func listRecords(zone: String) async throws -> [DNSRecord] {
        let rrsets = try await client.list(Self.zonePath(zone) + "/rrsets", key: "rrsets")
        return rrsets.flatMap { records(zone: zone, rrset: $0) }
    }

    public func createRecord(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let rrName = Self.rrsetName(name, zone: zone)
        let rrType = type.uppercased()
        let value = Self.value(content: content, priority: priority, type: rrType)
        let newRecord: JSONValue = .object(["value": .string(value)])

        if let existing = try await rrset(zone: zone, name: rrName, type: rrType) {
            if Self.sortedRecords(existing).contains(where: { $0.string("value") == value }) {
                throw KastellanError.invalidArgument("Record \(rrName) \(rrType) mit Wert \(value) existiert bereits in \(zone)")
            }
            let response = try await client.post(Self.rrsetPath(zone, rrName, rrType) + "/actions/add_records",
                                                 body: .object(["records": .array([newRecord])]))
            try await client.waitForActions(in: response)
            if let ttl, existing.int("ttl") != ttl {
                let ttlResponse = try await client.post(Self.rrsetPath(zone, rrName, rrType) + "/actions/change_ttl",
                                                        body: .object(["ttl": .int(ttl)]))
                try await client.waitForActions(in: ttlResponse)
            }
        } else {
            let body = JSONValue.compactObject([
                "name": .string(rrName),
                "type": .string(rrType),
                "ttl": ttl.map { .int($0) },
                "records": .array([newRecord]),
            ])
            let response = try await client.post(Self.zonePath(zone) + "/rrsets", body: body)
            try await client.waitForActions(in: response)
        }
        return try await record(zone: zone, name: rrName, type: rrType, value: value)
    }

    public func updateRecord(zone: String, providerRef: String, content: String?, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let (rrName, rrType, index) = try Self.parse(providerRef: providerRef)
        guard let existing = try await rrset(zone: zone, name: rrName, type: rrType) else {
            throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone)")
        }
        var records = Self.sortedRecords(existing)
        guard records.indices.contains(index), let oldValue = records[index].string("value") else {
            throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone)")
        }

        var newValue = oldValue
        if let content {
            newValue = Self.value(content: content, priority: priority ?? Self.priority(of: oldValue, type: rrType), type: rrType)
        } else if let priority {
            newValue = Self.value(content: Self.content(of: oldValue, type: rrType), priority: priority, type: rrType)
        }

        if newValue != oldValue {
            var updated = records[index].objectValue ?? [:]
            updated["value"] = .string(newValue)
            records[index] = .object(updated)
            let response = try await client.post(Self.rrsetPath(zone, rrName, rrType) + "/actions/set_records",
                                                 body: .object(["records": .array(records)]))
            try await client.waitForActions(in: response)
        }
        if let ttl, existing.int("ttl") != ttl {
            let response = try await client.post(Self.rrsetPath(zone, rrName, rrType) + "/actions/change_ttl",
                                                 body: .object(["ttl": .int(ttl)]))
            try await client.waitForActions(in: response)
        }
        return try await record(zone: zone, name: rrName, type: rrType, value: newValue)
    }

    public func deleteRecord(zone: String, providerRef: String) async throws {
        let (rrName, rrType, index) = try Self.parse(providerRef: providerRef)
        guard let existing = try await rrset(zone: zone, name: rrName, type: rrType) else {
            throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone)")
        }
        let records = Self.sortedRecords(existing)
        guard records.indices.contains(index), let value = records[index].string("value") else {
            throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone)")
        }
        let response: JSONValue
        if records.count == 1 {
            // Ein RRSet darf nicht leer sein: letzten Wert löschen heißt RRSet löschen.
            response = try await client.delete(Self.rrsetPath(zone, rrName, rrType))
        } else {
            response = try await client.post(Self.rrsetPath(zone, rrName, rrType) + "/actions/remove_records",
                                             body: .object(["records": .array([.object(["value": .string(value)])])]))
        }
        try await client.waitForActions(in: response)
    }

    // MARK: - Mapping

    func zone(_ item: JSONValue) -> DNSZone {
        var extra = Self.extra(from: item, keys: ["mode", "status", "record_count", "labels", "protection", "registrar", "created"])
        extra["primary_nameservers"] = .array(item.array("primary_nameservers").compactMap { $0.string("address").map { .string($0) } })
        if let assigned = item["authoritative_nameservers"]?["assigned"] { extra["nameservers"] = assigned }
        if let delegation = item["authoritative_nameservers"]?.string("delegation_status") { extra["delegation_status"] = .string(delegation) }
        return DNSZone(ref: ref(String(item.int("id") ?? 0)), zone: item.string("name") ?? "", defaultTTL: item.int("ttl"), extra: extra)
    }

    func records(zone: String, rrset: JSONValue) -> [DNSRecord] {
        let name = rrset.string("name") ?? "@"
        let type = rrset.string("type") ?? ""
        let ttl = rrset.int("ttl")
        let labels = rrset.labels()
        let protection = rrset["protection"]?.bool("change") ?? false
        return Self.sortedRecords(rrset).enumerated().map { index, record in
            var extra: Extra = [:]
            if let comment = record.string("comment") { extra["comment"] = .string(comment) }
            if !labels.isEmpty { extra["labels"] = .labels(labels) }
            if protection { extra["protected"] = .bool(true) }
            if let id = rrset.string("id") { extra["rrset_id"] = .string(id) }
            return DNSRecord(ref: ref("\(name)/\(type)/\(index)"), zone: zone, name: name, type: type,
                             content: record.string("value") ?? "", ttl: ttl, extra: extra)
        }
    }

    /// Werte eines RRSets nach `value` sortiert, damit der Index im `provider_ref` stabil ist.
    static func sortedRecords(_ rrset: JSONValue) -> [JSONValue] {
        rrset.array("records").sorted { ($0.string("value") ?? "") < ($1.string("value") ?? "") }
    }

    // MARK: - Helfer

    /// RRSet lesen, `nil` wenn es nicht existiert.
    private func rrset(zone: String, name: String, type: String) async throws -> JSONValue? {
        do {
            return try await client.get(Self.rrsetPath(zone, name, type))["rrset"]
        } catch KastellanError.notFound(_) {
            return nil
        }
    }

    /// Den Record mit diesem Wert nach einer Änderung neu lesen (für Index und TTL).
    private func record(zone: String, name: String, type: String, value: String) async throws -> DNSRecord {
        guard let set = try await rrset(zone: zone, name: name, type: type),
              let record = records(zone: zone, rrset: set).first(where: { $0.content == value }) else {
            throw KastellanError.notFound("DNS-Record \(name) \(type) \(value) in Zone \(zone) nach der Änderung")
        }
        return record
    }

    /// Zonen lassen sich per ID oder Name ansprechen; Kastellan nutzt den Namen.
    static func zonePath(_ zone: String) -> String {
        "/zones/\(zone.lowercased())"
    }

    static func rrsetPath(_ zone: String, _ name: String, _ type: String) -> String {
        zonePath(zone) + "/rrsets/\(name)/\(type)"
    }

    /// Name relativ zur Zone: leer, `@` oder der Zonenname selbst werden zum Apex `@`,
    /// ein voll qualifizierter Name verliert das Zonen-Suffix.
    static func rrsetName(_ name: String, zone: String) -> String {
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        let z = zone.lowercased()
        if n.isEmpty || n == "@" || n == z { return "@" }
        if n.hasSuffix("." + z) { n.removeLast(z.count + 1) }
        return n
    }

    /// `<name>/<type>/<index>` zerlegen. Der Name darf keinen Schrägstrich enthalten.
    static func parse(providerRef: String) throws -> (name: String, type: String, index: Int) {
        let parts = providerRef.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, let index = Int(parts[2]), index >= 0 else {
            throw KastellanError.invalidArgument("provider_ref \(providerRef) hat nicht die Form name/type/index")
        }
        return (parts[0], parts[1].uppercased(), index)
    }

    /// Typen, deren Wert mit einer Priorität beginnt (`10 mail.example.com.`).
    static let priorityTypes: Set<String> = ["MX", "SRV"]

    /// Wert für Hetzner: bei MX/SRV Priorität und Inhalt kombiniert, sonst der Inhalt.
    static func value(content: String, priority: Int?, type: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard priorityTypes.contains(type), let priority else { return trimmed }
        return "\(priority) \(trimmed)"
    }

    /// Führende Priorität eines MX/SRV-Werts, `nil` bei anderen Typen.
    static func priority(of value: String, type: String) -> Int? {
        guard priorityTypes.contains(type) else { return nil }
        return value.split(separator: " ", maxSplits: 1).first.flatMap { Int($0) }
    }

    /// MX/SRV-Wert ohne führende Priorität.
    static func content(of value: String, type: String) -> String {
        guard priority(of: value, type: type) != nil else { return value }
        let parts = value.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : value
    }
}

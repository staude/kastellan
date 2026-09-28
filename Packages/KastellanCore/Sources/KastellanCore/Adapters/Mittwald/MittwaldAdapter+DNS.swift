import Foundation

// Schreibende DNS-Operationen bei Mittwald. Es gibt keine Einzelrecords: `PUT
// /dns-zones/{id}/record-sets/{a|mx|txt|srv|cname|caa}` ersetzt das komplette Set eines Typs,
// ein leeres Objekt löscht es. Der Adapter liest die Zone, wendet alle Änderungen auf die
// betroffenen Sets an und schreibt je Set genau einen PUT. Eine Zone gilt je Hostname, deshalb
// muss `name` der Apex (`@`) sein; Subdomains bekommen ihre eigene Zone über den Ingress.
// Ein von Mittwald verwaltetes A- oder MX-Set (`managed`) wird beim ersten Schreiben zu einem
// eigenen Set; die verwalteten Werte sind über die API nicht lesbar und gehen dabei verloren,
// das Ergebnis vermerkt es. Zurück auf „verwaltet“ geht über `set-managed` (extra.reset_managed
// bei dns_record_apply, siehe Katalog).

extension MittwaldAdapter {
    static let recordSetForType: [String: String] = ["A": "a", "AAAA": "a", "MX": "mx", "TXT": "txt", "SRV": "srv", "CNAME": "cname", "CAA": "caa"]
    static let minimumTTL = 60
    static let maximumTTL = 86_400

    struct SetValue {
        var type: String
        var content: String
        var priority: Int?
    }

    static func ttlSettings(_ ttl: Int?) -> JSONValue {
        guard let ttl else { return .object(["ttl": .object(["auto": .bool(true)])]) }
        return .object(["ttl": .object(["seconds": .int(min(max(ttl, minimumTTL), maximumTTL))])])
    }

    /// Body für ein Record-Set aus Kastellan-Werten; leere Liste → leeres Objekt (Set löschen).
    static func setBody(_ key: String, values: [SetValue], ttl: Int?) throws -> JSONValue {
        guard !values.isEmpty else { return .object([:]) }
        let settings = ttlSettings(ttl)
        switch key {
        case "a":
            return .object([
                "a": .array(values.filter { $0.type == "A" }.map { .string($0.content) }),
                "aaaa": .array(values.filter { $0.type == "AAAA" }.map { .string($0.content) }),
                "settings": settings,
            ])
        case "mx":
            return .object(["records": .array(values.map { .object(["fqdn": .string($0.content), "priority": .int($0.priority ?? 10)]) }), "settings": settings])
        case "txt":
            return .object(["entries": .array(values.map { .string(unquote($0.content)) }), "settings": settings])
        case "srv":
            return .object(["records": .array(try values.map { v in
                let parts = v.content.split(separator: " ").map(String.init)
                guard parts.count == 3, let weight = Int(parts[0]), let port = Int(parts[1]) else {
                    throw KastellanError.invalidArgument("SRV-Inhalt als \"gewicht port ziel\" angeben: \(v.content)")
                }
                return .object(["fqdn": .string(parts[2]), "port": .int(port), "priority": .int(v.priority ?? 0), "weight": .int(weight)])
            }), "settings": settings])
        case "cname":
            guard values.count == 1 else { throw KastellanError.invalidArgument("Mittwald erlaubt genau einen CNAME je Zone") }
            return .object(["fqdn": .string(values[0].content), "settings": settings])
        case "caa":
            return .object(["records": .array(try values.map { v in
                let parts = v.content.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3, let flags = Int(parts[0]) else {
                    throw KastellanError.invalidArgument("CAA-Inhalt als \"flags tag wert\" angeben: \(v.content)")
                }
                return .object(["flags": .int(flags), "tag": .string(parts[1]), "value": .string(unquote(parts[2]))])
            }), "settings": settings])
        default:
            throw KastellanError.unsupported("Mittwald: Record-Typ für Set \(key) nicht unterstützt")
        }
    }

    static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { t.removeFirst(); t.removeLast() }
        return t
    }

    static func apexName(_ name: String, zone: String) throws -> String {
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        let z = zone.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if n.isEmpty || n == "@" || n == z { return "@" }
        throw KastellanError.invalidArgument("Mittwald führt je Hostname eine eigene Zone; \(name).\(z) über subdomain_create (Ingress) anlegen und dann in der Zone \(n.hasSuffix("." + z) ? n : n + "." + z) schreiben")
    }
}

extension MittwaldAdapter {
    public func createRecord(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let t = type.uppercased()
        let results = try await applyChanges(zone: zone, changes: [.create(name: name, type: t, content: content, ttl: ttl, priority: priority)])
        guard let created = results.first(where: { $0.type == t && Self.unquote($0.content) == Self.unquote(content) }) else {
            throw KastellanError.notFound("DNS-Record \(type) \(content) in Zone \(zone) nach dem Anlegen")
        }
        return created
    }

    public func updateRecord(zone: String, providerRef: String, content: String?, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let (_, type, _) = try Self.parse(providerRef)
        let results = try await applyChanges(zone: zone, changes: [.update(providerRef: providerRef, content: content, ttl: ttl, priority: priority)])
        if let content, let updated = results.first(where: { $0.type == type && Self.unquote($0.content) == Self.unquote(content) }) { return updated }
        guard let updated = results.first(where: { $0.ref.providerRef == providerRef }) else {
            throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone) nach der Änderung")
        }
        return updated
    }

    public func deleteRecord(zone: String, providerRef: String) async throws {
        _ = try await applyChanges(zone: zone, changes: [.delete(providerRef: providerRef)])
    }

    public func applyChanges(zone: String, changes: [DNSChange]) async throws -> [DNSRecord] {
        let zoneItem = try await zoneObject(named: zone)
        guard let zoneID = zoneItem.string("id") else { throw KastellanError.notFound("DNS-Zone \(zone) bei Mittwald") }
        let current = records(zone: zoneItem)

        // Aktuelle Werte je Set, in der Reihenfolge der Inventar-Liste (Index = provider_ref).
        var sets: [String: [SetValue]] = [:]
        var ttls: [String: Int?] = [:]
        var touched = Set<String>()
        var wasManaged = Set<String>()
        for r in current {
            let key = Self.recordSetForType[r.type] ?? r.type.lowercased()
            sets[key, default: []].append(SetValue(type: r.type, content: r.content, priority: r.priority))
            ttls[key] = r.ttl
        }
        if let set = zoneItem["recordSet"] {
            if set["combinedARecords"]?["managedBy"] != nil { wasManaged.insert("a") }
            if set["mx"]?.bool("managed") == true { wasManaged.insert("mx") }
        }

        for change in changes {
            switch change {
            case .create(let name, let type, let content, let ttl, let priority):
                _ = try Self.apexName(name, zone: zone)
                let t = type.uppercased()
                guard let key = Self.recordSetForType[t] else {
                    throw KastellanError.unsupported("Mittwald: Record-Typ \(t) wird nicht unterstützt (nur A, AAAA, MX, TXT, SRV, CNAME, CAA)")
                }
                if key == "cname", !(sets["cname"] ?? []).isEmpty {
                    throw KastellanError.invalidArgument("Mittwald erlaubt genau einen CNAME je Zone; vorhandenen Record ändern oder löschen")
                }
                sets[key, default: []].append(SetValue(type: t, content: content.trimmingCharacters(in: .whitespaces), priority: priority))
                if let ttl { ttls[key] = ttl }
                touched.insert(key)
            case .update(let providerRef, let content, let ttl, let priority):
                let (_, type, index) = try Self.parse(providerRef)
                let key = Self.recordSetForType[type] ?? type.lowercased()
                guard let list = sets[key], let position = Self.position(of: index, type: type, in: list) else {
                    throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone)")
                }
                var v = list[position]
                if let content { v.content = content.trimmingCharacters(in: .whitespaces) }
                if let priority { v.priority = priority }
                sets[key]![position] = v
                if let ttl { ttls[key] = ttl }
                touched.insert(key)
            case .delete(let providerRef):
                let (_, type, index) = try Self.parse(providerRef)
                let key = Self.recordSetForType[type] ?? type.lowercased()
                guard let list = sets[key], let position = Self.position(of: index, type: type, in: list) else {
                    throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone)")
                }
                sets[key]!.remove(at: position)
                touched.insert(key)
            }
        }

        for key in touched.sorted() {
            let body = try Self.setBody(key, values: sets[key] ?? [], ttl: ttls[key] ?? nil)
            try await client.put("/dns-zones/\(zoneID)/record-sets/\(key)", body: body)
        }
        var result = records(zone: try await client.get("/dns-zones/\(zoneID)"))
        for key in touched where wasManaged.contains(key) {
            for i in result.indices where Self.recordSetForType[result[i].type] == key {
                result[i].extra["note"] = .string("Set \(key.uppercased()) war von Mittwald verwaltet; die verwalteten Werte sind ersetzt. Zurück auf verwaltet über set-managed.")
            }
        }
        return result
    }

    /// `<zoneId>/<typ>/<index>` zerlegen.
    static func parse(_ providerRef: String) throws -> (zone: String, type: String, index: Int) {
        let parts = providerRef.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let index = Int(parts[2]) else {
            throw KastellanError.invalidArgument("provider_ref \(providerRef) hat nicht die Form zone/typ/index")
        }
        return (parts[0], parts[1].uppercased(), index)
    }

    /// Index innerhalb eines Typs (A und AAAA teilen sich ein Set) auf die Position in der Set-Liste.
    static func position(of index: Int, type: String, in list: [SetValue]) -> Int? {
        var seen = 0
        for (i, v) in list.enumerated() where v.type == type {
            if seen == index { return i }
            seen += 1
        }
        return nil
    }
}

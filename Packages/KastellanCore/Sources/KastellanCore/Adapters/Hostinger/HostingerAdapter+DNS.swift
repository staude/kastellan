import Foundation

// Domains und DNS bei Hostinger. Domains aus dem Portfolio (`/api/domains/v1/portfolio`), Details
// mit Nameservern, Lock und Privacy; Änderungen über eigene Endpunkte (Nameserver, Lock,
// Privacy, Weiterleitung). DNS arbeitet in RRsets ohne IDs: `GET /api/dns/v1/zones/{domain}`
// liefert `{name, type, ttl, records[{content, is_disabled}]}`, `PUT` mit `overwrite: true`
// ersetzt RRsets gleichen Namens und Typs, `DELETE` mit `filters[{name, type}]` löscht ein
// RRset. Kastellan zeigt jeden Wert als Record mit `provider_ref` `<name>/<typ>/<index>`
// (Werte sortiert). Vor jedem Schreiben läuft `validate` als Probelauf, und die Kennung des
// jüngsten Snapshots landet im Ergebnis (`extra.snapshot_before`), damit ein Restore möglich bleibt.

extension HostingerAdapter: DomainAdapter {
    static func ownNameserver(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("hostinger") || n.contains("dns-parking.com")
    }

    func domain(_ item: JSONValue) -> Domain {
        var extra = Self.extra(from: item, keys: ["type", "expires_at", "created_at", "registered_at", "is_locked", "is_privacy_protected", "is_lockable", "is_privacy_protection_allowed", "domain_contacts", "message"])
        var nameservers: [String] = []
        if let ns = item["name_servers"]?.objectValue {
            nameservers = ns.keys.sorted().compactMap { ns[$0]?.stringValue }.filter { !$0.isEmpty }
        }
        if let child = item["child_name_servers"] { extra["child_name_servers"] = child }
        let id = item.int("id").map(String.init) ?? item.string("domain") ?? ""
        return Domain(ref: ref(id), fqdn: item.string("domain") ?? "", status: item.string("status"), nameservers: nameservers,
                      dnsManagedHere: nameservers.isEmpty ? false : nameservers.contains { Self.ownNameserver($0) }, extra: extra)
    }

    public func listDomains() async throws -> [Domain] {
        try await client.list("/api/domains/v1/portfolio").map { domain($0) }.sorted { $0.fqdn < $1.fqdn }
    }

    public func getDomain(fqdn: String) async throws -> Domain? {
        do {
            var d = domain(try await client.get("/api/domains/v1/portfolio/\(Self.normalized(fqdn))"))
            if let fw = try? await client.get("/api/domains/v1/forwarding/\(Self.normalized(fqdn))"), fw.string("redirect_url") != nil {
                d.extra["forwarding"] = .object(["url": .string(fw.string("redirect_url") ?? ""), "type": .string(fw.string("redirect_type") ?? "")])
            }
            return d
        } catch KastellanError.notFound { return nil }
    }

    public func createDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        throw KastellanError.unsupported("Hostinger: Domains werden über den Kauf im hPanel registriert, nicht über Kastellan")
    }

    /// Nameserver (extra.nameservers), Lock (extra.lock), Privacy (extra.privacy), Weiterleitung
    /// (extra.forward_url mit extra.redirect_type 301|302, leer entfernt sie).
    public func updateDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        let name = Self.normalized(fqdn)
        if let ns = extra["nameservers"]?.arrayValue?.compactMap(\.stringValue), !ns.isEmpty {
            guard ns.count >= 2, ns.count <= 4 else { throw KastellanError.invalidArgument("Hostinger: zwei bis vier Nameserver angeben") }
            var body: [String: JSONValue] = [:]
            for (i, n) in ns.enumerated() { body["ns\(i + 1)"] = .string(n) }
            try await client.put("/api/domains/v1/portfolio/\(name)/nameservers", body: .object(body))
        }
        if let lock = extra["lock"]?.boolValue {
            if lock { try await client.put("/api/domains/v1/portfolio/\(name)/domain-lock") }
            else { try await client.delete("/api/domains/v1/portfolio/\(name)/domain-lock") }
        }
        if let privacy = extra["privacy"]?.boolValue {
            if privacy { try await client.put("/api/domains/v1/portfolio/\(name)/privacy-protection") }
            else { try await client.delete("/api/domains/v1/portfolio/\(name)/privacy-protection") }
        }
        if let url = extra["forward_url"]?.stringValue {
            if url.isEmpty {
                try await client.delete("/api/domains/v1/forwarding/\(name)")
            } else {
                let type = extra["redirect_type"]?.stringValue ?? "301"
                let existing = try? await client.get("/api/domains/v1/forwarding/\(name)")
                if existing?.string("redirect_url") != nil {
                    try await client.put("/api/domains/v1/forwarding/\(name)", body: .object(["redirect_type": .string(type), "redirect_url": .string(url)]))
                } else {
                    try await client.post("/api/domains/v1/forwarding", body: .object(["domain": .string(name), "redirect_type": .string(type), "redirect_url": .string(url)]))
                }
            }
        }
        guard let updated = try await getDomain(fqdn: name) else { throw KastellanError.notFound("Domain \(fqdn) bei Hostinger") }
        return updated
    }

    public func deleteDomain(fqdn: String) async throws {
        throw KastellanError.unsupported("Hostinger: Domains werden nicht über Kastellan gekündigt")
    }

    static func normalized(_ fqdn: String) -> String {
        fqdn.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}

extension HostingerAdapter: DNSAdapter {
    static let priorityTypes: Set<String> = ["MX", "SRV"]
    static let recordTypes: Set<String> = ["A", "AAAA", "CNAME", "ALIAS", "MX", "TXT", "NS", "SOA", "SRV", "CAA"]

    struct RRSet {
        var name: String
        var type: String
        var ttl: Int?
        var values: [String]
    }

    static func value(content: String, priority: Int?, type: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard priorityTypes.contains(type), let priority else { return trimmed }
        return "\(priority) \(trimmed)"
    }

    static func priority(of value: String, type: String) -> Int? {
        guard priorityTypes.contains(type) else { return nil }
        return value.split(separator: " ", maxSplits: 1).first.flatMap { Int($0) }
    }

    static func content(of value: String, type: String) -> String {
        guard priority(of: value, type: type) != nil else { return value }
        let parts = value.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : value
    }

    static func relativeName(_ name: String, zone: String) -> String {
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        let z = zone.lowercased()
        if n.isEmpty || n == "@" || n == z { return "@" }
        if n.hasSuffix("." + z) { n.removeLast(z.count + 1) }
        return n
    }

    func rrsets(zone: String) async throws -> [RRSet] {
        try await client.get("/api/dns/v1/zones/\(zone)").arrayValue?.map { set in
            RRSet(name: Self.relativeName(set.string("name") ?? "@", zone: zone), type: (set.string("type") ?? "").uppercased(), ttl: set.int("ttl"),
                  values: set.array("records").compactMap { $0.string("content") }.sorted())
        } ?? []
    }

    func records(zone: String, sets: [RRSet]) -> [DNSRecord] {
        sets.flatMap { set in
            set.values.enumerated().map { index, value in
                DNSRecord(ref: ref("\(set.name)/\(set.type)/\(index)"), zone: zone, name: set.name, type: set.type,
                          content: Self.content(of: value, type: set.type), ttl: set.ttl, priority: Self.priority(of: value, type: set.type))
            }
        }.sorted { ($0.name, $0.type, $0.content) < ($1.name, $1.type, $1.content) }
    }

    public func listZones() async throws -> [DNSZone] {
        try await client.list("/api/domains/v1/portfolio").compactMap { item in
            guard let name = item.string("domain") else { return nil }
            return DNSZone(ref: ref(name), zone: name, defaultTTL: nil, extra: Self.extra(from: item, keys: ["status", "type"]))
        }.sorted { $0.zone < $1.zone }
    }

    public func listRecords(zone: String) async throws -> [DNSRecord] {
        let z = Self.normalized(zone)
        return records(zone: z, sets: try await rrsets(zone: z))
    }

    public func createRecord(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let t = type.uppercased()
        let results = try await applyChanges(zone: zone, changes: [.create(name: name, type: t, content: content, ttl: ttl, priority: priority)])
        let rel = Self.relativeName(name, zone: Self.normalized(zone))
        guard let created = results.first(where: { $0.name == rel && $0.type == t && $0.content == content.trimmingCharacters(in: .whitespaces) }) else {
            throw KastellanError.notFound("DNS-Record \(name) \(type) in Zone \(zone) nach dem Anlegen")
        }
        return created
    }

    public func updateRecord(zone: String, providerRef: String, content: String?, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let (name, type, _) = try Self.parse(providerRef)
        let results = try await applyChanges(zone: zone, changes: [.update(providerRef: providerRef, content: content, ttl: ttl, priority: priority)])
        if let content, let updated = results.first(where: { $0.name == name && $0.type == type && $0.content == content.trimmingCharacters(in: .whitespaces) }) { return updated }
        guard let updated = results.first(where: { $0.ref.providerRef == providerRef }) else {
            throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(zone) nach der Änderung")
        }
        return updated
    }

    public func deleteRecord(zone: String, providerRef: String) async throws {
        _ = try await applyChanges(zone: zone, changes: [.delete(providerRef: providerRef)])
    }

    public func applyChanges(zone: String, changes: [DNSChange]) async throws -> [DNSRecord] {
        let z = Self.normalized(zone)
        var sets = try await rrsets(zone: z)
        var touched = Set<String>()
        func key(_ name: String, _ type: String) -> String { "\(name)/\(type)" }
        func index(_ name: String, _ type: String) -> Int? { sets.firstIndex { $0.name == name && $0.type == type } }

        for change in changes {
            switch change {
            case .create(let rawName, let rawType, let content, let ttl, let priority):
                let name = Self.relativeName(rawName, zone: z), type = rawType.uppercased()
                guard Self.recordTypes.contains(type) else { throw KastellanError.unsupported("Hostinger: Record-Typ \(type) wird nicht unterstützt") }
                let value = Self.value(content: content, priority: priority, type: type)
                if let i = index(name, type) {
                    guard !sets[i].values.contains(value) else { throw KastellanError.invalidArgument("Record \(name) \(type) mit Wert \(value) existiert bereits in \(z)") }
                    sets[i].values.append(value)
                    if let ttl { sets[i].ttl = ttl }
                } else {
                    sets.append(RRSet(name: name, type: type, ttl: ttl, values: [value]))
                }
                touched.insert(key(name, type))
            case .update(let providerRef, let content, let ttl, let priority):
                let (name, type, position) = try Self.parse(providerRef)
                guard let i = index(name, type), sets[i].values.indices.contains(position) else {
                    throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(z)")
                }
                let old = sets[i].values[position]
                var newValue = old
                if let content {
                    newValue = Self.value(content: content, priority: priority ?? Self.priority(of: old, type: type), type: type)
                } else if let priority {
                    newValue = Self.value(content: Self.content(of: old, type: type), priority: priority, type: type)
                }
                sets[i].values[position] = newValue
                if let ttl { sets[i].ttl = ttl }
                touched.insert(key(name, type))
            case .delete(let providerRef):
                let (name, type, position) = try Self.parse(providerRef)
                guard let i = index(name, type), sets[i].values.indices.contains(position) else {
                    throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(z)")
                }
                sets[i].values.remove(at: position)
                touched.insert(key(name, type))
            }
        }

        let toWrite = sets.filter { touched.contains(key($0.name, $0.type)) && !$0.values.isEmpty }
        let toDelete = sets.filter { touched.contains(key($0.name, $0.type)) && $0.values.isEmpty }
        let snapshotBefore = (try? await client.list("/api/dns/v1/snapshots/\(z)"))?.compactMap { $0.int("id") }.max()

        if !toWrite.isEmpty {
            let body: JSONValue = .object(["overwrite": .bool(true), "zone": .array(toWrite.map { set in
                JSONValue.compactObject([
                    "name": .string(set.name), "type": .string(set.type), "ttl": set.ttl.map { .int($0) },
                    "records": .array(set.values.map { .object(["content": .string($0)]) }),
                ])
            })])
            try await client.post("/api/dns/v1/zones/\(z)/validate", body: body)
            try await client.put("/api/dns/v1/zones/\(z)", body: body)
        }
        if !toDelete.isEmpty {
            try await client.delete("/api/dns/v1/zones/\(z)", body: .object(["filters": .array(toDelete.map { .object(["name": .string($0.name), "type": .string($0.type)]) })]))
        }
        var result = records(zone: z, sets: try await rrsets(zone: z))
        if let snapshotBefore {
            for i in result.indices where touched.contains(key(result[i].name, result[i].type)) {
                result[i].extra["snapshot_before"] = .int(snapshotBefore)
            }
        }
        return result
    }

    static func parse(_ providerRef: String) throws -> (name: String, type: String, index: Int) {
        let parts = providerRef.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, let index = Int(parts[2]), index >= 0 else {
            throw KastellanError.invalidArgument("provider_ref \(providerRef) hat nicht die Form name/typ/index")
        }
        return (parts[0].lowercased(), parts[1].uppercased(), index)
    }
}

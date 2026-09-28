import Foundation

// Zonen und DNS-Records über `GET /zones` und `/zones/{zone_id}/dns_records`
// (https://developers.cloudflare.com/api/resources/dns/subresources/records/). Cloudflare führt
// Record-Namen als volle Hostnamen und `ttl` 1 für „automatisch“; Kastellan verwendet Namen
// relativ zur Zone (`@` für den Apex) und `ttl` nil. `proxied` und `comment` landen in `extra`.

extension CloudflareAdapter: DNSAdapter {
    /// Cloudflare-Wert für „TTL automatisch“.
    static let automaticTTL = 1

    // MARK: - Namensabbildung

    /// `www.example.com` in Zone `example.com` → `www`, `example.com` → `@`.
    static func relativeName(_ fqdn: String, zone: String) -> String {
        let z = zoneName(zone)
        let n = zoneName(fqdn)
        if n == z || n.isEmpty { return "@" }
        if n.hasSuffix("." + z) { return String(n.dropLast(z.count + 1)) }
        return n
    }

    /// `www` in Zone `example.com` → `www.example.com`, `@` → `example.com`. Volle Namen bleiben.
    static func absoluteName(_ name: String, zone: String) -> String {
        let z = zoneName(zone)
        let n = zoneName(name)
        if n.isEmpty || n == "@" || n == z { return z }
        if n.hasSuffix("." + z) { return n }
        return n + "." + z
    }

    // MARK: - Abbildung

    func zone(from raw: CloudflareZone) -> DNSZone {
        var extra: Extra = ["id": .string(raw.id)]
        if let status = raw.status { extra["status"] = .string(status) }
        if let plan = raw.plan?.name { extra["plan"] = .string(plan) }
        if let ns = raw.nameServers, !ns.isEmpty { extra["name_servers"] = .array(ns.map(JSONValue.string)) }
        return DNSZone(ref: ref(raw.id), zone: Self.zoneName(raw.name), extra: extra)
    }

    func record(from raw: CloudflareDNSRecord, zone: String) -> DNSRecord {
        let z = Self.zoneName(raw.zoneName ?? zone)
        var extra: Extra = ["id": .string(raw.id)]
        if let proxied = raw.proxied { extra["proxied"] = .bool(proxied) }
        if let comment = raw.comment, !comment.isEmpty { extra["comment"] = .string(comment) }
        return DNSRecord(
            ref: ref(raw.id),
            zone: z,
            name: Self.relativeName(raw.name, zone: z),
            type: raw.type,
            content: raw.content ?? "",
            ttl: raw.ttl.flatMap { $0 == Self.automaticTTL ? nil : $0 },
            priority: raw.priority,
            extra: extra
        )
    }

    /// Body für `POST dns_records` und `posts[]` im Batch.
    static func createBody(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) -> JSONValue {
        var body: [String: JSONValue] = [
            "name": .string(absoluteName(name, zone: zone)),
            "type": .string(type.uppercased()),
            "content": .string(content),
            "ttl": .int(ttl ?? automaticTTL),
        ]
        if let priority { body["priority"] = .int(priority) }
        return .object(body)
    }

    /// Body für `PATCH dns_records/{id}` und `patches[]` im Batch: nur die gesetzten Felder.
    static func patchBody(providerRef: String?, content: String?, ttl: Int?, priority: Int?) -> JSONValue {
        var body: [String: JSONValue] = [:]
        if let providerRef { body["id"] = .string(providerRef) }
        if let content { body["content"] = .string(content) }
        if let ttl { body["ttl"] = .int(ttl) }
        if let priority { body["priority"] = .int(priority) }
        return .object(body)
    }

    /// Body für `POST dns_records/batch`: `deletes`, `patches`, `posts`, jeweils nur wenn belegt.
    static func batchBody(zone: String, changes: [DNSChange]) -> JSONValue {
        var deletes: [JSONValue] = []
        var patches: [JSONValue] = []
        var posts: [JSONValue] = []
        for change in changes {
            switch change {
            case let .create(name, type, content, ttl, priority):
                posts.append(createBody(zone: zone, name: name, type: type, content: content, ttl: ttl, priority: priority))
            case let .update(providerRef, content, ttl, priority):
                patches.append(patchBody(providerRef: providerRef, content: content, ttl: ttl, priority: priority))
            case let .delete(providerRef):
                deletes.append(.object(["id": .string(providerRef)]))
            }
        }
        var body: [String: JSONValue] = [:]
        if !deletes.isEmpty { body["deletes"] = .array(deletes) }
        if !patches.isEmpty { body["patches"] = .array(patches) }
        if !posts.isEmpty { body["posts"] = .array(posts) }
        return .object(body)
    }

    // MARK: - DNSAdapter

    public func listZones() async throws -> [DNSZone] {
        let zones: [CloudflareZone] = try await client.list("/zones")
        await client.remember(zones: zones)
        return zones.map(zone(from:))
    }

    public func listRecords(zone: String) async throws -> [DNSRecord] {
        let z = Self.zoneName(zone)
        let id = try await zoneID(z)
        let records: [CloudflareDNSRecord] = try await client.list("/zones/\(id)/dns_records")
        return records.map { record(from: $0, zone: z) }
    }

    public func createRecord(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let z = Self.zoneName(zone)
        let id = try await zoneID(z)
        let body = Self.createBody(zone: z, name: name, type: type, content: content, ttl: ttl, priority: priority)
        let raw: CloudflareDNSRecord = try await client.post("/zones/\(id)/dns_records", body: body)
        return record(from: raw, zone: z)
    }

    public func updateRecord(zone: String, providerRef: String, content: String?, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let z = Self.zoneName(zone)
        let id = try await zoneID(z)
        let body = Self.patchBody(providerRef: nil, content: content, ttl: ttl, priority: priority)
        let raw: CloudflareDNSRecord = try await client.patch("/zones/\(id)/dns_records/\(providerRef)", body: body)
        return record(from: raw, zone: z)
    }

    public func deleteRecord(zone: String, providerRef: String) async throws {
        let id = try await zoneID(zone)
        let _: CloudflareDeletedObject = try await client.delete("/zones/\(id)/dns_records/\(providerRef)")
    }

    /// Alle Änderungen in einer Transaktion über `POST /zones/{zone_id}/dns_records/batch`.
    /// Zurück kommen die angelegten und geänderten Records; Gelöschte sind nicht dabei.
    public func applyChanges(zone: String, changes: [DNSChange]) async throws -> [DNSRecord] {
        guard !changes.isEmpty else { return [] }
        let z = Self.zoneName(zone)
        let id = try await zoneID(z)
        let body = Self.batchBody(zone: z, changes: changes)
        let result: CloudflareDNSBatchResult = try await client.post("/zones/\(id)/dns_records/batch", body: body)
        return ((result.posts ?? []) + (result.patches ?? []) + (result.puts ?? [])).map { record(from: $0, zone: z) }
    }
}

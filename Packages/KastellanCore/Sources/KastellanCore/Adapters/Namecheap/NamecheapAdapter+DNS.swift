import CryptoKit
import Foundation

// DNS bei Namecheap. `domains.dns.getHosts` liefert alle Records einer Domain, `setHosts` ersetzt
// sie vollständig. Jede Änderung liest deshalb die Zone, ändert lokal und schreibt die ganze Liste
// mit allen Feldern zurück, auch Namecheap-eigene Typen (URL, URL301, FRAME, ALIAS, MXE), die
// Kastellan sonst nicht kennt. Namen bestehender Records werden nie umgeschrieben.
//
// `EmailType` (MX, MXE, FWD, OX, GMAIL) gehört zur Zone: fehlt er beim Schreiben, setzt Namecheap
// den Standard und eigene MX-Records verschwinden. Der Adapter schickt immer den gelesenen Wert
// mit und stellt nur dann auf MX (bzw. MXE) um, wenn ein solcher Record angelegt wird.
//
// `HostId` ändert sich bei jedem `setHosts`. Die Kennung eines Records ist deshalb
// `<name>/<typ>/<hash>` mit einem Hash über Name, Typ, Inhalt, Priorität und TTL; gleiche Records
// bekommen `-2`, `-3` angehängt. Hat jemand den Record seit dem Lesen geändert, passt die Kennung
// nicht mehr und die Änderung wird abgelehnt. `extra.zone_hash` beschreibt den ganzen Stand.

extension NamecheapAdapter: DNSAdapter {
    static let recordTypes: Set<String> = ["A", "AAAA", "ALIAS", "CAA", "CNAME", "MX", "MXE", "NS", "TXT", "URL", "URL301", "FRAME"]
    static let emailTypes: Set<String> = ["MX", "MXE", "FWD", "OX", "GMAIL"]
    static let defaultTTL = 1800

    struct Host: Equatable {
        var name: String
        var type: String
        var address: String
        var mxPref: Int
        var ttl: Int
        var flag: String?
        var tag: String?
        var active: Bool

        var fingerprint: String {
            let digest = SHA256.hash(data: Data("\(name.lowercased())|\(type)|\(address)|\(type == "MX" ? mxPref : 0)|\(ttl)".utf8))
            return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Zone {
        var domain: String
        var emailType: String
        var hosts: [Host]

        var hash: String {
            let text = hosts.map { "\($0.name.lowercased())|\($0.type)|\($0.address)|\($0.mxPref)|\($0.ttl)" }.sorted().joined(separator: "\n") + "\n" + emailType
            return SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        }

        /// Kennungen in Listenreihenfolge, Duplikate mit Zähler.
        var refs: [String] {
            var seen: [String: Int] = [:]
            return hosts.map { host in
                let base = "\(host.name)/\(host.type)/\(host.fingerprint)"
                seen[base, default: 0] += 1
                return seen[base]! == 1 ? base : "\(base)-\(seen[base]!)"
            }
        }
    }

    func readZone(_ zone: String) async throws -> Zone {
        let (sld, tld) = try NamecheapClient.split(zone)
        let response = try await client.call("namecheap.domains.dns.getHosts", [("SLD", sld), ("TLD", tld)])
        guard let result = response.firstDescendant("DomainDNSGetHostsResult") else {
            throw KastellanError.provider("Namecheap: getHosts ohne Ergebnis für \(zone)")
        }
        if result.bool("IsUsingOurDNS") == false {
            throw KastellanError.unsupported("Namecheap: \(zone) nutzt nicht die Namecheap-Nameserver, DNS lässt sich hier nicht ändern")
        }
        let hosts = result.children("host").map { h in
            Host(name: h["Name"] ?? "@", type: (h["Type"] ?? "").uppercased(), address: h["Address"] ?? "",
                 mxPref: h.int("MXPref") ?? 10, ttl: h.int("TTL") ?? Self.defaultTTL,
                 flag: h["Flag"], tag: h["Tag"], active: h.bool("IsActive") ?? true)
        }
        return Zone(domain: zone, emailType: (result["EmailType"] ?? "").uppercased(), hosts: hosts)
    }

    func writeZone(_ zone: Zone) async throws {
        let (sld, tld) = try NamecheapClient.split(zone.domain)
        var params: [(String, String)] = [("SLD", sld), ("TLD", tld)]
        if Self.emailTypes.contains(zone.emailType) { params.append(("EmailType", zone.emailType)) }
        for (i, host) in zone.hosts.enumerated() {
            let n = i + 1
            params += [("HostName\(n)", host.name), ("RecordType\(n)", host.type), ("Address\(n)", host.address),
                       ("MXPref\(n)", String(host.mxPref)), ("TTL\(n)", String(host.ttl))]
            if let flag = host.flag { params.append(("Flag\(n)", flag)) }
            if let tag = host.tag { params.append(("Tag\(n)", tag)) }
        }
        let response = try await client.call("namecheap.domains.dns.setHosts", params)
        if response.firstDescendant("DomainDNSSetHostsResult")?.bool("IsSuccess") == false {
            throw KastellanError.provider("Namecheap: setHosts für \(zone.domain) wurde nicht übernommen")
        }
    }

    func records(_ zone: Zone) -> [DNSRecord] {
        let hash = zone.hash
        return zip(zone.hosts, zone.refs).map { host, providerRef in
            var extra: Extra = ["zone_hash": .string(hash)]
            if !host.active { extra["active"] = .bool(false) }
            if let flag = host.flag { extra["flag"] = .string(flag) }
            if let tag = host.tag { extra["tag"] = .string(tag) }
            if host.name.contains(".") && host.name.lowercased().hasSuffix(zone.domain.lowercased()) {
                extra["warning"] = .string("Name enthält schon die Domain, der Record heißt effektiv \(host.name).\(zone.domain)")
            }
            if ["URL", "URL301", "FRAME"].contains(host.type) { extra["namecheap_redirect"] = .bool(true) }
            return DNSRecord(ref: ref(providerRef), zone: zone.domain, name: host.name, type: host.type, content: host.address,
                             ttl: host.ttl, priority: host.type == "MX" ? host.mxPref : nil, extra: extra)
        }.sorted { ($0.name, $0.type, $0.content) < ($1.name, $1.type, $1.content) }
    }

    static func relativeName(_ name: String, zone: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        let z = zone.lowercased()
        if n.isEmpty || n == "@" || n == z { return "@" }
        if n.hasSuffix("." + z) { n.removeLast(z.count + 1) }
        return n
    }

    // MARK: - DNSAdapter

    /// Nur Domains mit Namecheap-DNS; bei den anderen liegt die Zone beim fremden Nameserver.
    public func listZones() async throws -> [DNSZone] {
        try await client.list("namecheap.domains.getList", item: "Domain").compactMap { item in
            guard let name = item["Name"]?.lowercased(), item.bool("IsOurDNS") != false else { return nil }
            return DNSZone(ref: ref(name), zone: name, defaultTTL: Self.defaultTTL, extra: [:])
        }.sorted { $0.zone < $1.zone }
    }

    public func listRecords(zone: String) async throws -> [DNSRecord] {
        let z = try await readZone(Self.normalized(zone))
        var out = records(z)
        if !out.isEmpty { out[0].extra["email_type"] = .string(z.emailType) }
        return out
    }

    public func createRecord(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let z = Self.normalized(zone)
        let t = type.uppercased()
        let results = try await applyChanges(zone: z, changes: [.create(name: name, type: t, content: content, ttl: ttl, priority: priority)])
        let rel = Self.relativeName(name, zone: z)
        let value = content.trimmingCharacters(in: .whitespaces)
        guard let created = results.first(where: { $0.name.lowercased() == rel && $0.type == t && $0.content == value }) else {
            throw KastellanError.notFound("DNS-Record \(name) \(t) in Zone \(z) nach dem Anlegen")
        }
        return created
    }

    public func updateRecord(zone: String, providerRef: String, content: String?, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let z = Self.normalized(zone)
        let parts = providerRef.split(separator: "/", omittingEmptySubsequences: false)
        let results = try await applyChanges(zone: z, changes: [.update(providerRef: providerRef, content: content, ttl: ttl, priority: priority)])
        guard parts.count == 3 else { throw KastellanError.invalidArgument("provider_ref \(providerRef) hat nicht die Form name/typ/hash") }
        let name = String(parts[0]), type = String(parts[1])
        let candidates = results.filter { $0.name == name && $0.type == type }
        if let content, let match = candidates.first(where: { $0.content == content.trimmingCharacters(in: .whitespaces) }) { return match }
        guard let only = candidates.first else { throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(z) nach der Änderung") }
        return only
    }

    public func deleteRecord(zone: String, providerRef: String) async throws {
        _ = try await applyChanges(zone: zone, changes: [.delete(providerRef: providerRef)])
    }

    /// Liest die Zone, wendet alle Änderungen lokal an und schreibt sie mit einem `setHosts` zurück.
    public func applyChanges(zone: String, changes: [DNSChange]) async throws -> [DNSRecord] {
        let z = Self.normalized(zone)
        var current = try await readZone(z)
        let refs = current.refs
        var hosts: [Host?] = current.hosts.map { $0 }
        var added: [Host] = []

        func index(of providerRef: String) throws -> Int {
            guard let i = refs.firstIndex(of: providerRef), hosts[i] != nil else {
                throw KastellanError.notFound("DNS-Record \(providerRef) in \(z). Er wurde inzwischen geändert oder gelöscht; bitte die Records neu lesen.")
            }
            return i
        }

        for change in changes {
            switch change {
            case .create(let rawName, let rawType, let content, let ttl, let priority):
                let type = rawType.uppercased()
                guard Self.recordTypes.contains(type) else { throw KastellanError.unsupported("Namecheap: Record-Typ \(type) wird nicht unterstützt") }
                let value = content.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { throw KastellanError.invalidArgument("Inhalt des Records fehlt") }
                let host = Host(name: Self.relativeName(rawName, zone: z), type: type, address: value,
                                mxPref: type == "MX" ? (priority ?? 10) : 10, ttl: ttl ?? Self.defaultTTL, flag: nil, tag: nil, active: true)
                let exists = (hosts.compactMap { $0 } + added).contains { $0.name.lowercased() == host.name && $0.type == type && $0.address == value }
                guard !exists else { throw KastellanError.invalidArgument("Record \(host.name) \(type) mit Inhalt \(value) existiert bereits in \(z)") }
                added.append(host)
                if type == "MX" { current.emailType = "MX" }
                if type == "MXE" { current.emailType = "MXE" }
            case .update(let providerRef, let content, let ttl, let priority):
                let i = try index(of: providerRef)
                var host = hosts[i]!
                if let content { host.address = content.trimmingCharacters(in: .whitespaces) }
                if let ttl { host.ttl = ttl }
                if let priority, host.type == "MX" { host.mxPref = priority }
                hosts[i] = host
            case .delete(let providerRef):
                hosts[try index(of: providerRef)] = nil
            }
        }

        let next = Zone(domain: z, emailType: current.emailType, hosts: hosts.compactMap { $0 } + added)
        guard next.hosts.count <= 150 else { throw KastellanError.invalidArgument("Namecheap erlaubt höchstens 150 Records je Domain") }
        try await writeZone(next)
        return records(try await readZone(z))
    }
}

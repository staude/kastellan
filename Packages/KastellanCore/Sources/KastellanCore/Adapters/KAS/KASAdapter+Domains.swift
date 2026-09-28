import Foundation

// KAS-Funktionen für Domains, Subdomains, DNS und DKIM auf das kanonische Modell.
// Feldnamen stammen aus echten Antworten (Fixtures `get_domains`, `get_subdomains`,
// `get_dns_settings`, `get_dkim`). add_dkim/delete_dkim sind undokumentiert.

// MARK: - Domain

extension KASAdapter: DomainAdapter {
    static let domainMapped: Set<String> = ["domain_name", "domain_path", "is_active"]

    func domain(from item: KASValue) -> Domain? {
        guard let name = item.string("domain_name") else { return nil }
        return Domain(
            ref: ref(name),
            fqdn: name,
            status: item.bool("is_active") == true ? "active" : "inactive",
            path: item.string("domain_path"),
            extra: Self.extra(from: item, excluding: Self.domainMapped)
        )
    }

    public func listDomains() async throws -> [Domain] {
        try await items("get_domains").compactMap(domain(from:))
    }

    public func getDomain(fqdn: String) async throws -> Domain? {
        try await listDomains().first { $0.fqdn.lowercased() == fqdn.lowercased() }
    }

    public func createDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        var params = Self.params(from: extra)
        params["domain_name"] = fqdn
        if let path { params["domain_path"] = path }
        try await call("add_domain", params)
        return try await getDomain(fqdn: fqdn)
            ?? Domain(ref: ref(fqdn), fqdn: fqdn, status: "active", path: path, extra: extra)
    }

    public func updateDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        var params = Self.params(from: extra)
        params["domain_name"] = fqdn
        if let path { params["domain_path"] = path }
        try await call("update_domain", params)
        guard let domain = try await getDomain(fqdn: fqdn) else {
            throw KastellanError.notFound("Domain \(fqdn)")
        }
        return domain
    }

    public func deleteDomain(fqdn: String) async throws {
        try await call("delete_domain", ["domain_name": fqdn])
    }
}

// MARK: - Subdomain

extension KASAdapter: SubdomainAdapter {
    static let subdomainMapped: Set<String> = ["subdomain_name", "subdomain_path", "subdomain_redirect_status"]

    /// Alles nach dem ersten Label: `app.beispiel.de` gehört zu `beispiel.de`.
    static func parent(of fqdn: String) -> String {
        fqdn.split(separator: ".").dropFirst().joined(separator: ".")
    }

    static func label(of fqdn: String) -> String {
        String(fqdn.split(separator: ".").first ?? "")
    }

    func subdomain(from item: KASValue) -> Subdomain? {
        guard let name = item.string("subdomain_name") else { return nil }
        let redirectStatus = item.string("subdomain_redirect_status") ?? "0"
        let path = item.string("subdomain_path")
        let isRedirect = redirectStatus != "0"
        var extra = Self.extra(from: item, excluding: Self.subdomainMapped)
        extra["subdomain_redirect_status"] = .string(redirectStatus)
        return Subdomain(
            ref: ref(name),
            fqdn: name,
            parent: Self.parent(of: name),
            targetPath: isRedirect ? nil : path,
            redirect: isRedirect ? path : nil,
            extra: extra
        )
    }

    public func listSubdomains(parent: String?) async throws -> [Subdomain] {
        let all = try await items("get_subdomains").compactMap(subdomain(from:))
        guard let parent, !parent.isEmpty else { return all }
        let wanted = parent.lowercased()
        return all.filter { $0.parent.lowercased() == wanted || $0.fqdn.lowercased().hasSuffix("." + wanted) }
    }

    func findSubdomain(fqdn: String) async throws -> Subdomain? {
        try await listSubdomains(parent: nil).first { $0.fqdn.lowercased() == fqdn.lowercased() }
    }

    /// Parameter für `add_subdomain`/`update_subdomain`: Ziel ist entweder ein Pfad oder eine Weiterleitung.
    private static func subdomainParams(targetPath: String?, redirect: String?, extra: Extra) -> [String: String] {
        var params = Self.params(from: extra)
        if let redirect, !redirect.isEmpty {
            params["subdomain_path"] = redirect
            params["subdomain_redirect_status"] = extra["subdomain_redirect_status"]?.stringValue ?? "301"
        } else if let targetPath {
            params["subdomain_path"] = targetPath
            params["subdomain_redirect_status"] = extra["subdomain_redirect_status"]?.stringValue ?? "0"
        }
        return params
    }

    public func createSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain {
        let label = Self.label(of: fqdn)
        let parent = Self.parent(of: fqdn)
        guard !label.isEmpty, parent.contains(".") else {
            throw KastellanError.invalidArgument("Subdomain braucht mindestens drei Labels: \(fqdn)")
        }
        var params = Self.subdomainParams(targetPath: targetPath, redirect: redirect, extra: extra)
        params["subdomain_name"] = label
        params["domain_name"] = parent
        try await call("add_subdomain", params)
        return try await findSubdomain(fqdn: fqdn)
            ?? Subdomain(ref: ref(fqdn), fqdn: fqdn, parent: parent, targetPath: targetPath, redirect: redirect, extra: extra)
    }

    public func updateSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain {
        var params = Self.subdomainParams(targetPath: targetPath, redirect: redirect, extra: extra)
        params["subdomain_name"] = fqdn
        try await call("update_subdomain", params)
        guard let subdomain = try await findSubdomain(fqdn: fqdn) else {
            throw KastellanError.notFound("Subdomain \(fqdn)")
        }
        return subdomain
    }

    public func deleteSubdomain(fqdn: String) async throws {
        try await call("delete_subdomain", ["subdomain_name": fqdn])
    }
}

// MARK: - DNS

extension KASAdapter: DNSAdapter {
    /// KAS erwartet `zone_host` mit Punkt am Ende.
    static func zoneHost(_ zone: String) -> String {
        let z = Self.zoneName(zone)
        return z + "."
    }

    /// Kanonischer Zonenname ohne Punkt am Ende, kleingeschrieben.
    static func zoneName(_ zone: String) -> String {
        var z = zone.lowercased()
        while z.hasSuffix(".") { z.removeLast() }
        return z
    }

    /// Record-Typen, bei denen `record_aux` eine Priorität ist.
    static let priorityTypes: Set<String> = ["MX", "SRV"]

    func record(from item: KASValue, zone: String) -> DNSRecord? {
        guard let id = item.string("record_id"), let type = item.string("record_type") else { return nil }
        let recordZone = Self.zoneName(item.string("record_zone") ?? zone)
        let aux = item.int("record_aux") ?? 0
        var extra: Extra = [:]
        if let changeable = item.bool("record_changeable") { extra["changeable"] = .bool(changeable) }
        if let deleteable = item.bool("record_deleteable") { extra["deleteable"] = .bool(deleteable) }
        if !Self.priorityTypes.contains(type.uppercased()), aux != 0 { extra["record_aux"] = .int(aux) }
        return DNSRecord(
            ref: ref(id),
            zone: recordZone,
            name: item.string("record_name") ?? "@",
            type: type,
            content: item.string("record_data") ?? "",
            ttl: nil,
            priority: Self.priorityTypes.contains(type.uppercased()) ? aux : nil,
            extra: extra
        )
    }

    public func listZones() async throws -> [DNSZone] {
        try await items("get_domains").compactMap { item in
            guard let name = item.string("domain_name") else { return nil }
            return DNSZone(ref: ref(name), zone: Self.zoneName(name))
        }
    }

    public func listRecords(zone: String) async throws -> [DNSRecord] {
        let z = Self.zoneName(zone)
        return try await items("get_dns_settings", ["zone_host": Self.zoneHost(z)]).compactMap { record(from: $0, zone: z) }
    }

    public func createRecord(zone: String, name: String, type: String, content: String, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let z = Self.zoneName(zone)
        let recordName = name == "@" ? "" : name
        let response = try await call("add_dns_settings", [
            "zone_host": Self.zoneHost(z),
            "record_type": type.uppercased(),
            "record_name": recordName,
            "record_data": content,
            "record_aux": String(priority ?? 0),
        ])
        if let id = response.returnInfo.string, !id.isEmpty {
            return DNSRecord(ref: ref(id), zone: z, name: name.isEmpty ? "@" : name, type: type, content: content,
                             ttl: nil, priority: priority)
        }
        // Kein Record-ID in der Antwort: nachlesen.
        let records = try await listRecords(zone: z)
        guard let created = records.last(where: {
            $0.name == (name.isEmpty ? "@" : name) && $0.type == type.uppercased() && $0.content == content
        }) else {
            throw KastellanError.provider("add_dns_settings hat den Record \(name) \(type) nicht angelegt")
        }
        return created
    }

    public func updateRecord(zone: String, providerRef: String, content: String?, ttl: Int?, priority: Int?) async throws -> DNSRecord {
        let z = Self.zoneName(zone)
        // KAS will bei update_dns_settings alle Felder, daher den aktuellen Stand nachlesen.
        guard let current = try await listRecords(zone: z).first(where: { $0.ref.providerRef == providerRef }) else {
            throw KastellanError.notFound("DNS-Record \(providerRef) in Zone \(z)")
        }
        var updated = current
        if let content { updated.content = content }
        if let priority { updated.priority = priority }
        let aux = updated.priority ?? (current.extra["record_aux"].flatMap { if case .int(let i) = $0 { i } else { nil } } ?? 0)
        try await call("update_dns_settings", [
            "record_id": providerRef,
            "record_name": updated.name == "@" ? "" : updated.name,
            "record_data": updated.content,
            "record_aux": String(aux),
        ])
        return updated
    }

    public func deleteRecord(zone: String, providerRef: String) async throws {
        try await call("delete_dns_settings", ["record_id": providerRef])
    }
}

// MARK: - DKIM

extension KASAdapter: DKIMAdapter {
    func dkim(from item: KASValue, domain: String) -> DKIMKey? {
        guard let selector = item.string("selector"), let key = item.string("public_key") else { return nil }
        return DKIMKey(
            ref: ref("\(domain)/\(selector)"),
            domain: domain,
            selector: selector,
            publicKey: key,
            active: true,
            validUntil: Self.date(item.string("valid_to")),
            extra: Self.extra(from: item, excluding: ["selector", "public_key", "valid_to"])
        )
    }

    public func getDKIM(domain: String) async throws -> DKIMKey? {
        let host = Self.zoneName(domain)
        return try await items("get_dkim", ["host": host]).compactMap { dkim(from: $0, domain: host) }.first
    }

    /// `add_dkim` ist undokumentiert (Community-SDK). Kennt KAS die Funktion nicht, kommt `unsupported`.
    public func createDKIM(domain: String) async throws -> DKIMKey {
        let host = Self.zoneName(domain)
        try await call("add_dkim", ["host": host, "check_foreign_nameserver": "N"])
        guard let key = try await getDKIM(domain: host) else {
            throw KastellanError.provider("add_dkim für \(host) lieferte keinen Schlüssel")
        }
        return key
    }

    public func deleteDKIM(domain: String) async throws {
        try await call("delete_dkim", ["host": Self.zoneName(domain)])
    }
}

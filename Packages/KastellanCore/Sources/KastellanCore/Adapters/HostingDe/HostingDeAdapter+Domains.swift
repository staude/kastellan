import Foundation

// Domains und Subdomains bei hosting.de. `domain` ist das Registrar-Objekt (`domainsFind`,
// `domainInfo`): Status, Nameserver, Vertragslaufzeit, Transfer-Lock. Registrierung, Änderung
// und Kündigung lösen Kosten und asynchrone Jobs aus und bleiben deshalb außen vor.
// `subdomain` ist ein VHost im Webhosting (`vhostsFind`, `vhostCreate`, `vhostUpdate`,
// `vhostDelete`): `webRoot` ist der Ordner unter `html/`, eine Weiterleitung ist eine
// Location vom Typ `redirect`. VHosts mit zwei Labels gelten als Domain-Hosting und tauchen
// in der Subdomain-Liste nicht auf. Updates schicken den kompletten VHost zurück.

extension HostingDeAdapter: DomainAdapter {
    public func listDomains() async throws -> [Domain] {
        try await client.findAll("domain", "domainsFind").map { domain($0) }.sorted { $0.fqdn < $1.fqdn }
    }

    public func getDomain(fqdn: String) async throws -> Domain? {
        let name = Self.normalized(fqdn)
        let filter = HostingDeFilter.or([.equal("DomainName", name), .equal("DomainNameUnicode", name)])
        return try await client.findPage("domain", "domainsFind", filter: filter, limit: 1).data.first.map { domain($0) }
    }

    public func createDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        throw KastellanError.unsupported("hosting.de: Domains werden nicht über Kastellan registriert; Hosting für eine Domain über subdomain_create (VHost) einrichten")
    }

    public func updateDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        throw KastellanError.unsupported("hosting.de: Domain-Einstellungen (Kontakte, Nameserver) werden nicht über Kastellan geändert")
    }

    public func deleteDomain(fqdn: String) async throws {
        throw KastellanError.unsupported("hosting.de: Domains werden nicht über Kastellan gekündigt")
    }

    func domain(_ item: JSONValue) -> Domain {
        let nameservers = item.array("nameservers").compactMap { $0.string("name") }
        var extra = Self.extra(from: item, keys: ["nameUnicode", "transferLockEnabled", "createDate", "currentContractPeriodEnd",
                                                   "nextContractPeriodStart", "deletionType", "deletionDate", "accountId"])
        extra["contacts"] = .array(item.array("contacts").map { c in
            .object(["type": .string(c.string("type") ?? ""), "contact": .string(c.string("contact") ?? "")])
        })
        let status = item.strings("status").joined(separator: ",")
        return Domain(ref: ref(item.string("id") ?? ""), fqdn: item.string("name") ?? "",
                      status: status.isEmpty ? item.string("status") : status,
                      nameservers: nameservers,
                      dnsManagedHere: nameservers.contains { Self.ownNameserver($0) },
                      extra: extra)
    }

    /// Nameserver der Plattform (hosting.de, http.net) erkennen.
    static func ownNameserver(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix("hosting.de") || n.hasSuffix("http.net") || n.hasSuffix("hosting.zone")
    }

    static func normalized(_ fqdn: String) -> String {
        fqdn.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}

extension HostingDeAdapter: SubdomainAdapter {
    public func listSubdomains(parent: String?) async throws -> [Subdomain] {
        var filter: HostingDeFilter?
        if let parent {
            let p = Self.normalized(parent)
            filter = .or([.equal("VHostDomainName", "*." + p), .equal("VHostDomainNameUnicode", "*." + p)])
        }
        let vhosts = try await client.findAll("webhosting", "vhostsFind", filter: filter)
        return vhosts.compactMap { subdomain($0) }.sorted { $0.fqdn < $1.fqdn }
    }

    public func createSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain {
        let name = Self.normalized(fqdn)
        let webspaceID = try await webspaceID(from: extra)
        var locations: [JSONValue] = [Self.defaultLocation]
        if let redirect { locations.append(Self.redirectLocation(redirect)) }
        let vhost = JSONValue.compactObject([
            "webspaceId": .string(webspaceID),
            "domainName": .string(name),
            "serverType": extra["server_type"] ?? .string("nginx"),
            "enableAlias": extra["enable_alias"] ?? .bool(false),
            "enableSystemAlias": extra["enable_system_alias"] ?? .bool(false),
            "redirectToPrimaryName": .bool(false),
            "webRoot": .string(Self.webRoot(targetPath, fqdn: name)),
            "phpVersion": extra["php_version"],
            "locations": .array(locations),
        ])
        let result = try await client.call("webhosting", "vhostCreate", ["vhost": vhost])
        var created = result.response
        if result.pending || created.string("status") != "active", let id = created.string("id") {
            created = try await waitForVHost(id, what: "VHost \(name)")
        }
        guard let sub = subdomain(created, force: true) else {
            throw KastellanError.provider("hosting.de: vhostCreate lieferte keinen VHost für \(name)")
        }
        return sub
    }

    public func updateSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain {
        let name = Self.normalized(fqdn)
        var vhost = try await vhost(named: name)
        var object = vhost.objectValue ?? [:]
        if let targetPath { object["webRoot"] = .string(Self.webRoot(targetPath, fqdn: name)) }
        if let redirect {
            var locations = vhost.array("locations").filter { $0.string("locationType") != "redirect" }
            if !redirect.isEmpty { locations.append(Self.redirectLocation(redirect)) }
            object["locations"] = .array(locations)
        }
        if let php = extra["php_version"] { object["phpVersion"] = php }
        // Nur-Lese-Felder gehören nicht in den Update-Aufruf.
        for key in ["addDate", "lastChangeDate", "systemAlias", "status", "blocked", "restorableUntil", "deletionScheduledFor"] {
            object.removeValue(forKey: key)
        }
        vhost = .object(object)
        let result = try await client.call("webhosting", "vhostUpdate", ["vhost": vhost])
        var updated = result.response
        if result.pending || updated.string("status") != "active", let id = updated.string("id") ?? object["id"]?.stringValue {
            updated = try await waitForVHost(id, what: "VHost \(name)")
        }
        guard let sub = subdomain(updated, force: true) else {
            throw KastellanError.provider("hosting.de: vhostUpdate lieferte keinen VHost für \(name)")
        }
        return sub
    }

    public func deleteSubdomain(fqdn: String) async throws {
        let name = Self.normalized(fqdn)
        let vhost = try await vhost(named: name)
        guard let id = vhost.string("id") else { throw KastellanError.notFound("VHost \(name)") }
        try await client.call("webhosting", "vhostDelete", ["vhostId": .string(id)])
    }

    // MARK: - Mapping

    /// VHost als Subdomain; `force` nimmt auch VHosts mit zwei Labels (Ergebnis eines Aufrufs).
    func subdomain(_ item: JSONValue, force: Bool = false) -> Subdomain? {
        guard let name = item.string("domainName") else { return nil }
        let labels = name.split(separator: ".")
        guard force || labels.count >= 3 else { return nil }
        let redirect = item.array("locations").first { $0.string("locationType") == "redirect" }?.string("redirectionUrl")
        var extra = Self.extra(from: item, keys: ["domainNameUnicode", "webspaceId", "serverType", "phpVersion", "status",
                                                   "enableAlias", "systemAlias", "additionalDomainNames", "restorableUntil", "lastChangeDate"])
        if let ssl = item["sslSettings"], ssl != .null { extra["ssl"] = ssl }
        return Subdomain(ref: ref(item.string("id") ?? ""), fqdn: name,
                         parent: labels.dropFirst().joined(separator: "."),
                         targetPath: item.string("webRoot").map { "html/" + $0 },
                         redirect: redirect, extra: extra)
    }

    // MARK: - Helfer

    static let defaultLocation: JSONValue = .object([
        "locationType": .string("generic"), "matchType": .string("default"), "matchString": .string(""),
        "phpEnabled": .bool(true), "directoryListingEnabled": .bool(false),
    ])

    /// Weiterleitung der ganzen Subdomain. Typ- und Matchwerte nach der Feldbeschreibung der
    /// Doku (`redirect`, `directory`); die Beispiele dort nutzen andere Werte, live prüfen.
    static func redirectLocation(_ url: String) -> JSONValue {
        .object([
            "locationType": .string("redirect"), "matchType": .string("directory"), "matchString": .string("/"),
            "redirectionUrl": .string(url), "redirectionStatus": .string("301"),
        ])
    }

    /// `webRoot` ist relativ zu `html/`; Kastellan-Pfade dürfen `html/` oder `/` voranstellen.
    static func webRoot(_ path: String?, fqdn: String) -> String {
        var p = (path ?? fqdn).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if p == "html" { p = "" }
        if p.hasPrefix("html/") { p.removeFirst(5) }
        return p.isEmpty ? fqdn : p
    }

    func vhost(named name: String) async throws -> JSONValue {
        let filter = HostingDeFilter.or([.equal("VHostDomainName", name), .equal("VHostDomainNameUnicode", name)])
        guard let item = try await client.findPage("webhosting", "vhostsFind", filter: filter, limit: 1).data.first else {
            throw KastellanError.notFound("VHost \(name) bei hosting.de")
        }
        return item
    }

    func waitForVHost(_ id: String, what: String) async throws -> JSONValue {
        let client = self.client
        return try await client.waitUntilActive(what) {
            try await client.findPage("webhosting", "vhostsFind", filter: .equal("VHostId", id), limit: 1).data.first
        }
    }

    /// Webspace aus `extra.webspace_id`, sonst der einzige vorhandene; bei mehreren ein Fehler mit Liste.
    func webspaceID(from extra: Extra) async throws -> String {
        if let id = extra["webspace_id"]?.stringValue, !id.isEmpty { return id }
        let spaces = try await client.findAll("webhosting", "webspacesFind")
        if spaces.count == 1, let id = spaces[0].string("id") { return id }
        let list = spaces.map { "\($0.string("name") ?? "?") (\($0.string("id") ?? "?"))" }.joined(separator: ", ")
        throw KastellanError.invalidArgument(spaces.isEmpty
            ? "hosting.de: kein Webspace vorhanden, VHost braucht einen Webspace"
            : "hosting.de: mehrere Webspaces, extra.webspace_id angeben: \(list)")
    }
}

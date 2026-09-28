import Foundation

// Lesendes Inventar bei Mittwald. Alle Listen laufen je Projekt (`projectIDs`), Einzelobjekte
// haben globale UUIDs. DNS liefert Mittwald als Record-Sets je Typ (`combinedARecords`, `mx`,
// `txt`, `srv`, `cname`, `caa`); der Adapter splittet sie in Einzelrecords mit `provider_ref`
// `<zoneId>/<typ>/<index>`. Postfach, Weiterleitung und Autoresponder sind eine Entität
// `MailAddress`. FTP gibt es nur als SFTP. Schreibende Operationen folgen in eigenen Dateien.

extension MittwaldAdapter {
    /// Ressourcen aller relevanten Projekte einsammeln.
    func acrossProjects<T>(_ extra: Extra = [:], _ body: @Sendable (String) async throws -> [T]) async throws -> [T] {
        var out: [T] = []
        for id in try await projectIDs(extra) { out += try await body(id) }
        return out
    }

    func bytesToMB(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value / 1_048_576
    }
}

// MARK: - Server

extension MittwaldAdapter: ServerAdapter {
    func server(_ item: JSONValue) -> Server {
        var extra = Self.extra(from: item, keys: ["shortId", "customerId", "clusterName", "storage", "description", "disabledReason", "readiness"])
        if let mt = item["machineType"] { extra["machineType"] = mt }
        return Server(ref: ref(item.string("id") ?? ""), name: item.string("description") ?? item.string("shortId") ?? "",
                      status: item.string("status") ?? "", type: item["machineType"]?.string("name"),
                      location: item.string("clusterName"), createdAt: MittwaldDates.date(item.string("createdAt")), extra: extra)
    }

    public func listServers() async throws -> [Server] {
        var query: [(String, String)] = []
        if let customerSetting { query.append(("customerId", customerSetting)) }
        return try await client.list("/servers", query: query).map { server($0) }.sorted { $0.name < $1.name }
    }

    public func getServer(providerRef: String) async throws -> Server? {
        do { return server(try await client.get("/servers/\(providerRef)")) } catch KastellanError.notFound { return nil }
    }

    public func createServer(_ spec: ServerSpec) async throws -> Server {
        throw KastellanError.unsupported("Mittwald: Server werden über Bestellungen im mStudio angelegt, nicht über Kastellan")
    }

    public func updateServer(providerRef: String, name: String?, labels: [String: String]?, power: ServerPowerAction?) async throws -> Server {
        if power != nil { throw KastellanError.unsupported("Mittwald: Server haben keine Power-Aktionen (verwaltete Plattform)") }
        if labels != nil { throw KastellanError.unsupported("Mittwald: Server haben keine Labels") }
        if let name, !name.isEmpty {
            try await client.patch("/servers/\(providerRef)", body: .object(["description": .string(name)]))
        }
        return server(try await client.get("/servers/\(providerRef)"))
    }

    public func deleteServer(providerRef: String) async throws {
        throw KastellanError.unsupported("Mittwald: Server werden über den Vertrag gekündigt, nicht über Kastellan")
    }
}

// MARK: - Domains und Ingress

extension MittwaldAdapter: DomainAdapter {
    func domain(_ item: JSONValue) -> Domain {
        var extra = Self.extra(from: item, keys: ["projectId", "usesDefaultNameserver", "connected", "deleted", "scheduledDeletionDate", "handles"])
        if let auth = item["authCode"], auth != .null { extra["authCodeExpires"] = auth["expires"] ?? .null }
        extra["processes"] = .array(item.array("processes").map { p in
            .object(["type": .string(p.string("processType") ?? ""), "state": .string(p.string("state") ?? ""), "status": .string(p.string("status") ?? "")])
        })
        let nameservers = item.strings("nameservers")
        return Domain(ref: ref(item.string("domainId") ?? ""), fqdn: item.string("domain") ?? "",
                      status: item.bool("deleted") == true ? "deleted" : (item.bool("connected") == true ? "active" : "not_connected"),
                      nameservers: nameservers, dnsManagedHere: item.bool("usesDefaultNameserver") ?? false, extra: extra)
    }

    public func listDomains() async throws -> [Domain] {
        try await acrossProjects { pid in
            try await self.client.list("/domains", query: [("projectId", pid)]).map { self.domain($0) }
        }.sorted { $0.fqdn < $1.fqdn }
    }

    public func getDomain(fqdn: String) async throws -> Domain? {
        try await listDomains().first { $0.fqdn.lowercased() == fqdn.lowercased() }
    }

    public func createDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        throw KastellanError.unsupported("Mittwald: Domains werden über Bestellungen registriert; Hosting für eine Domain über subdomain_create (Ingress)")
    }

    public func updateDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        throw KastellanError.unsupported("Mittwald: Domain-Einstellungen (Nameserver, Kontakte) werden nicht über Kastellan geändert")
    }

    public func deleteDomain(fqdn: String) async throws {
        throw KastellanError.unsupported("Mittwald: Domains werden nicht über Kastellan gekündigt")
    }
}

extension MittwaldAdapter: SubdomainAdapter {
    func subdomain(_ item: JSONValue) -> Subdomain {
        let host = item.string("hostname") ?? ""
        let labels = host.split(separator: ".")
        var extra = Self.extra(from: item, keys: ["projectId", "isDefault", "isDomain", "isEnabled", "ips", "dnsValidationErrors"])
        if let own = item["ownership"] { extra["ownership"] = own }
        if let tls = item["tls"] { extra["tls"] = tls }
        extra["paths"] = .array(item.array("paths"))
        let root = item.array("paths").first { $0.string("path") == "/" } ?? item.array("paths").first
        let target = root?["target"]
        var targetPath: String?
        if let installation = target?.string("installationId") { targetPath = "app:" + installation }
        else if target?.bool("useDefaultPage") == true { targetPath = "default-page" }
        else if let container = target?["container"]?.string("id") { targetPath = "container:" + container }
        return Subdomain(ref: ref(item.string("id") ?? ""), fqdn: host, parent: labels.dropFirst().joined(separator: "."),
                         targetPath: targetPath, redirect: target?.string("url"), extra: extra)
    }

    public func listSubdomains(parent: String?) async throws -> [Subdomain] {
        let all = try await acrossProjects { pid in
            try await self.client.list("/ingresses", query: [("projectId", pid)]).map { self.subdomain($0) }
        }
        let filtered = parent.map { p in all.filter { $0.fqdn.lowercased().hasSuffix("." + p.lowercased()) } } ?? all
        return filtered.sorted { $0.fqdn < $1.fqdn }
    }



}

// MARK: - DNS

extension MittwaldAdapter: DNSAdapter {
    static let recordSetKeys: [(set: String, type: String)] = [("combinedARecords", "A"), ("mx", "MX"), ("txt", "TXT"), ("srv", "SRV"), ("cname", "CNAME"), ("caa", "CAA")]

    func zone(_ item: JSONValue) -> DNSZone {
        var extra: Extra = [:]
        if let set = item["recordSet"] {
            if let a = set["combinedARecords"], a["managedBy"] != nil { extra["a_managed"] = .bool(true) }
            if let mx = set["mx"], mx.bool("managed") == true { extra["mx_managed"] = .bool(true) }
        }
        return DNSZone(ref: ref(item.string("id") ?? ""), zone: item.string("domain") ?? "", defaultTTL: nil, extra: extra)
    }

    /// Record-Sets einer Zone in Einzelrecords. Reihenfolge innerhalb eines Typs ist stabil
    /// sortiert, damit `provider_ref` `<zoneId>/<typ>/<index>` zwischen Aufrufen gleich bleibt.
    func records(zone item: JSONValue) -> [DNSRecord] {
        let zoneID = item.string("id") ?? ""
        let zoneName = item.string("domain") ?? ""
        guard let set = item["recordSet"] else { return [] }
        var out: [DNSRecord] = []
        func ttl(_ component: JSONValue?) -> Int? { component?["settings"]?["ttl"]?.int("seconds") }
        func add(_ type: String, _ values: [(content: String, priority: Int?, extra: Extra)], ttl: Int?, managed: Bool) {
            for (index, v) in values.enumerated() {
                var extra = v.extra
                if managed { extra["managed"] = .bool(true) }
                out.append(DNSRecord(ref: ref("\(zoneID)/\(type)/\(index)"), zone: zoneName, name: "@", type: type,
                                     content: v.content, ttl: ttl, priority: v.priority, extra: extra))
            }
        }
        if let a = set["combinedARecords"] {
            let managed = a["managedBy"] != nil
            add("A", a.strings("a").sorted().map { ($0, nil, [:]) }, ttl: ttl(a), managed: managed)
            add("AAAA", a.strings("aaaa").sorted().map { ($0, nil, [:]) }, ttl: ttl(a), managed: managed)
        }
        if let mx = set["mx"] {
            let managed = mx.bool("managed") == true
            let records = mx.array("records").sorted { ($0.int("priority") ?? 0, $0.string("fqdn") ?? "") < ($1.int("priority") ?? 0, $1.string("fqdn") ?? "") }
            add("MX", records.map { ($0.string("fqdn") ?? "", $0.int("priority"), [:]) }, ttl: ttl(mx), managed: managed)
        }
        if let txt = set["txt"] {
            add("TXT", txt.strings("entries").sorted().map { ($0, nil, [:]) }, ttl: ttl(txt), managed: false)
        }
        if let srv = set["srv"] {
            let records = srv.array("records").sorted { ($0.int("priority") ?? 0, $0.string("fqdn") ?? "") < ($1.int("priority") ?? 0, $1.string("fqdn") ?? "") }
            add("SRV", records.map { r in
                ("\(r.int("weight") ?? 0) \(r.int("port") ?? 0) \(r.string("fqdn") ?? "")", r.int("priority"),
                 ["weight": .int(r.int("weight") ?? 0), "port": .int(r.int("port") ?? 0), "fqdn": .string(r.string("fqdn") ?? "")])
            }, ttl: ttl(srv), managed: false)
        }
        if let cname = set["cname"], let fqdn = cname.string("fqdn") {
            add("CNAME", [(fqdn, nil, [:])], ttl: ttl(cname), managed: false)
        }
        if let caa = set["caa"] {
            let records = caa.array("records").sorted { ($0.string("tag") ?? "", $0.string("value") ?? "") < ($1.string("tag") ?? "", $1.string("value") ?? "") }
            add("CAA", records.map { r in
                ("\(r.int("flags") ?? 0) \(r.string("tag") ?? "") \"\(r.string("value") ?? "")\"", nil,
                 ["flags": .int(r.int("flags") ?? 0), "tag": .string(r.string("tag") ?? ""), "value": .string(r.string("value") ?? "")])
            }, ttl: ttl(caa), managed: false)
        }
        return out
    }

    func zoneObject(named zone: String) async throws -> JSONValue {
        let name = zone.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        for pid in try await projectIDs() {
            if let z = try await client.list("/projects/\(pid)/dns-zones").first(where: { $0.string("domain")?.lowercased() == name }) {
                return z
            }
        }
        throw KastellanError.notFound("DNS-Zone \(zone) bei Mittwald")
    }

    public func listZones() async throws -> [DNSZone] {
        try await acrossProjects { pid in
            try await self.client.list("/projects/\(pid)/dns-zones").map { self.zone($0) }
        }.sorted { $0.zone < $1.zone }
    }

    public func listRecords(zone: String) async throws -> [DNSRecord] {
        records(zone: try await zoneObject(named: zone))
    }



}

// MARK: - Mail

extension MittwaldAdapter {
    func mailAddresses(_ extra: Extra = [:]) async throws -> [JSONValue] {
        try await acrossProjects(extra) { pid in try await self.client.list("/projects/\(pid)/mail-addresses") }
    }

    func mailAddress(_ address: String) async throws -> JSONValue {
        let a = address.lowercased()
        guard let item = try await mailAddresses().first(where: { $0.string("address")?.lowercased() == a }) else {
            throw KastellanError.notFound("Mailadresse \(address) bei Mittwald")
        }
        return item
    }

    func mailExtra(_ item: JSONValue) -> Extra {
        var extra = Self.extra(from: item, keys: ["projectId", "isArchived", "receivingDisabled", "updatedAt", "originalAddress"])
        if let box = item["mailbox"], box != .null {
            extra["mailbox_name"] = box["name"] ?? .null
            extra["sendingEnabled"] = box["sendingEnabled"] ?? .null
            extra["passwordUpdatedAt"] = box["passwordUpdatedAt"] ?? .null
            if let spam = box["spamProtection"] { extra["spamProtection"] = spam }
        }
        if let r = item["autoResponder"], r != .null { extra["autoResponder"] = r }
        return extra.filter { $0.value != .null }
    }
}

extension MittwaldAdapter: MailboxAdapter {
    func mailbox(_ item: JSONValue) -> Mailbox {
        let box = item["mailbox"]
        let spam = box?["spamProtection"]
        return Mailbox(ref: ref(item.string("id") ?? ""), address: item.string("address") ?? "",
                       quotaMB: box?["storageInBytes"]?.int("limit").flatMap { $0 < 0 ? nil : $0 / 1_048_576 },
                       usedMB: bytesToMB(box?["storageInBytes"]?["current"]?.int("value")),
                       status: item.bool("receivingDisabled") == true ? "receiving_disabled" : "active",
                       spamFilter: spam.map { ($0.bool("active") ?? false) ? "on" : "off" }, senderAliases: [],
                       copyTo: item.strings("forwardAddresses"), extra: mailExtra(item))
    }

    public func listMailboxes(domain: String?) async throws -> [Mailbox] {
        let d = domain?.lowercased()
        return try await mailAddresses().filter { $0["mailbox"] != nil && $0["mailbox"] != .null }
            .filter { d == nil || ($0.string("address") ?? "").lowercased().hasSuffix("@" + d!) }
            .map { mailbox($0) }.sorted { $0.address < $1.address }
    }

    public func getMailbox(address: String) async throws -> Mailbox? {
        let item = try await mailAddress(address)
        guard item["mailbox"] != nil, item["mailbox"] != .null else { return nil }
        return mailbox(item)
    }

}

extension MittwaldAdapter: MailForwardAdapter {
    func forward(_ item: JSONValue) -> MailForward {
        let hasMailbox = item["mailbox"] != nil && item["mailbox"] != .null
        return MailForward(ref: ref(item.string("id") ?? ""), address: item.string("address") ?? "", targets: item.strings("forwardAddresses"),
                           keepCopy: hasMailbox, status: item.bool("receivingDisabled") == true ? .disabled : .active, extra: mailExtra(item))
    }

    public func listForwards(domain: String?) async throws -> [MailForward] {
        let d = domain?.lowercased()
        return try await mailAddresses().filter { !$0.strings("forwardAddresses").isEmpty }
            .filter { d == nil || ($0.string("address") ?? "").lowercased().hasSuffix("@" + d!) }
            .map { forward($0) }.sorted { $0.address < $1.address }
    }

}

extension MittwaldAdapter: MailAutoresponderAdapter {
    func autoresponder(address: String, item: JSONValue) -> MailAutoresponder? {
        guard let r = item["autoResponder"], r != .null else { return nil }
        return MailAutoresponder(ref: ref(item.string("id") ?? ""), address: address, active: r.bool("active") ?? false, subject: nil,
                                 text: r.string("message") ?? "", from: MittwaldDates.date(r.string("startsAt")), until: MittwaldDates.date(r.string("expiresAt")))
    }

    public func getAutoresponder(address: String) async throws -> MailAutoresponder? {
        autoresponder(address: address, item: try await mailAddress(address))
    }

}

// MARK: - Datenbanken

extension MittwaldAdapter: DatabaseAdapter {
    func database(_ item: JSONValue) -> Database {
        var extra = Self.extra(from: item, keys: ["projectId", "externalHostname", "status", "version", "isShared", "storageUsageInBytes", "createdAt"])
        if let main = item["mainUser"], main != .null {
            extra["main_user"] = .string(main.string("name") ?? "")
            extra["main_user_id"] = .string(main.string("id") ?? "")
            extra["main_user_status"] = .string(main.string("status") ?? "")
        }
        extra["engine_family"] = .string("mysql")
        return Database(ref: ref(item.string("id") ?? ""), name: item.string("name") ?? "", engine: "mysql", host: item.string("hostname"),
                        users: [item["mainUser"]?.string("name")].compactMap { $0 }, comment: item.string("description"), extra: extra)
    }

    func redis(_ item: JSONValue) -> Database {
        var extra = Self.extra(from: item, keys: ["projectId", "status", "version", "port", "storageUsageInBytes", "createdAt", "configuration"])
        extra["engine_family"] = .string("redis")
        return Database(ref: ref(item.string("id") ?? ""), name: item.string("name") ?? "", engine: "redis", host: item.string("hostname"),
                        users: [], comment: item.string("description"), extra: extra)
    }

    public func listDatabases() async throws -> [Database] {
        try await acrossProjects { pid in
            let mysql = try await self.client.list("/projects/\(pid)/mysql-databases").map { self.database($0) }
            let redis = (try? await self.client.list("/projects/\(pid)/redis-databases"))?.map { self.redis($0) } ?? []
            return mysql + redis
        }.sorted { $0.name < $1.name }
    }

}

// MARK: - SSH und SFTP

extension MittwaldAdapter: SSHUserAdapter {
    func sshUser(_ item: JSONValue) -> SSHUser {
        var extra = Self.extra(from: item, keys: ["projectId", "description", "active", "hasPassword", "expiresAt", "createdAt"])
        extra["keys"] = .array(item.array("publicKeys").map { .object(["comment": .string($0.string("comment") ?? "")]) })
        return SSHUser(ref: ref(item.string("id") ?? ""), username: item.string("userName") ?? "",
                       publicKeys: item.array("publicKeys").compactMap { $0.string("key") }, extra: extra)
    }

    public func listSSHUsers() async throws -> [SSHUser] {
        try await acrossProjects { pid in try await self.client.list("/projects/\(pid)/ssh-users").map { self.sshUser($0) } }.sorted { $0.username < $1.username }
    }

}

extension MittwaldAdapter: FTPUserAdapter {
    func sftpUser(_ item: JSONValue) -> FTPUser {
        var extra = Self.extra(from: item, keys: ["projectId", "description", "active", "hasPassword", "expiresAt", "accessLevel", "directories", "createdAt"])
        extra["protocol"] = .string("sftp")
        extra["public_keys"] = .int(item.array("publicKeys").count)
        return FTPUser(ref: ref(item.string("id") ?? ""), username: item.string("userName") ?? "",
                       homePath: item.strings("directories").first, status: item.bool("active") == false ? "inactive" : "active", extra: extra)
    }

    public func listFTPUsers() async throws -> [FTPUser] {
        try await acrossProjects { pid in try await self.client.list("/projects/\(pid)/sftp-users").map { self.sftpUser($0) } }.sorted { $0.username < $1.username }
    }

}

// MARK: - Cronjobs

extension MittwaldAdapter: CronJobAdapter {
    func cronJob(_ item: JSONValue) -> CronJob {
        var extra = Self.extra(from: item, keys: ["projectId", "shortId", "appInstallationId", "timeout", "timeZone", "email", "concurrencyPolicy", "nextExecutionTime", "failedExecutionAlertThreshold"])
        let target = item["target"]
        let destination = target?["destination"] ?? item["destination"]
        var command: String?
        if let path = destination?.string("path") {
            command = [destination?.string("interpreter"), path, destination?.string("parameters")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        } else if let cmd = target?.string("command") {
            command = cmd
            extra["stackId"] = target?["stackId"] ?? .null
            extra["serviceIdentifier"] = target?["serviceIdentifier"] ?? .null
        }
        if let last = item["latestExecution"], last != .null {
            extra["latestExecution"] = .object(["status": last["status"] ?? .null, "successful": last["successful"] ?? .null, "start": last["start"] ?? .null])
        }
        return CronJob(ref: ref(item.string("id") ?? ""), schedule: item.string("interval") ?? "", url: destination?.string("url"),
                       command: command, comment: item.string("description"), active: item.bool("active") ?? true, extra: extra.filter { $0.value != .null })
    }

    public func listCronJobs() async throws -> [CronJob] {
        try await acrossProjects { pid in try await self.client.list("/projects/\(pid)/cronjobs").map { self.cronJob($0) } }
    }

}

// MARK: - Zertifikate

extension MittwaldAdapter: CertificateAdapter {
    static let certificateTypes = [0: "unspecified", 1: "internal", 2: "external", 3: "dns"]

    func certificate(_ item: JSONValue) -> Certificate {
        var extra = Self.extra(from: item, keys: ["projectId", "dnsNames", "isExpired", "certificateOrderId", "certificateRequestId"])
        if let t = item.int("certificateType") { extra["certificateType"] = .string(Self.certificateTypes[t] ?? String(t)) }
        return Certificate(ref: ref(item.string("id") ?? ""), hostname: item.string("commonName") ?? "", issuer: item.string("issuer"),
                           validUntil: MittwaldDates.date(item.string("validTo")), autoRenew: item.int("certificateType") == 1 ? true : nil,
                           forceHTTPS: nil, extra: extra)
    }

    public func listCertificates() async throws -> [Certificate] {
        try await acrossProjects { pid in try await self.client.list("/certificates", query: [("projectId", pid)]).map { self.certificate($0) } }
            .sorted { $0.hostname < $1.hostname }
    }

}

// MARK: - Mitgliedschaften

extension MittwaldAdapter: SubaccountAdapter {
    func membership(_ item: JSONValue) -> Subaccount {
        var extra = Self.extra(from: item, keys: ["projectId", "role", "inherited", "expiresAt", "mfa", "memberSince", "userId", "firstName", "lastName"])
        extra["kind"] = .string("membership")
        let name = [item.string("firstName"), item.string("lastName")].compactMap { $0 }.joined(separator: " ")
        return Subaccount(ref: ref(item.string("id") ?? ""), login: item.string("email") ?? item.string("userId") ?? "",
                          comment: [name, item.string("role") ?? ""].filter { !$0.isEmpty }.joined(separator: ", "), extra: extra)
    }

    func invite(_ item: JSONValue) -> Subaccount {
        var extra = Self.extra(from: item, keys: ["projectId", "role", "membershipExpiresAt", "message"])
        extra["kind"] = .string("invite")
        return Subaccount(ref: ref(item.string("id") ?? ""), login: item.string("mailAddress") ?? "",
                          comment: "Einladung offen, Rolle \(item.string("role") ?? "?")", extra: extra)
    }

    public func listSubaccounts() async throws -> [Subaccount] {
        try await acrossProjects { pid in
            let members = try await self.client.list("/projects/\(pid)/memberships").map { self.membership($0) }
            let invites = (try? await self.client.list("/projects/\(pid)/invites"))?.map { self.invite($0) } ?? []
            return members + invites
        }.sorted { $0.login < $1.login }
    }

}

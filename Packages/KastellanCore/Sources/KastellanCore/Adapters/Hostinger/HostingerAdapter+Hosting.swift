import Foundation

// Webhosting bei Hostinger (`/api/hosting/v1`). Kontext ist eine Website mit ihrem Hosting-
// `username` (aus `GET /websites`, Typen main, addon, parked, subdomain). Subdomains hängen an
// einer Website, Datenbanken und Cronjobs am Account (`/accounts/{username}/…`). Eine Datenbank
// entsteht zusammen mit Nutzer und Passwort, Cronjobs lassen sich nur anlegen und löschen.

extension HostingerAdapter {
    struct Website {
        let domain: String
        let username: String
        let type: String
        let parent: String?
        let rootDirectory: String?
    }

    func websites() async throws -> [Website] {
        try await client.list("/api/hosting/v1/websites").compactMap { w in
            guard let domain = w.string("domain"), let user = w.string("username") else { return nil }
            return Website(domain: domain, username: user, type: w.string("vhost_type") ?? "", parent: w.string("parent_domain"), rootDirectory: w.string("root_directory"))
        }
    }

    /// Website aus `extra.website`, der Verbindungs-Einstellung oder der einzigen Hauptseite.
    func website(_ hint: String?) async throws -> Website {
        let all = try await websites()
        let wanted = (hint ?? connection.settings["website"]).map { Self.normalized($0) }
        if let wanted, !wanted.isEmpty {
            guard let site = all.first(where: { $0.domain.lowercased() == wanted }) else { throw KastellanError.notFound("Website \(wanted) bei Hostinger") }
            return site
        }
        let mains = all.filter { $0.type == "main" }
        if mains.count == 1 { return mains[0] }
        if all.count == 1 { return all[0] }
        let list = all.map { "\($0.domain) (\($0.type))" }.joined(separator: ", ")
        throw KastellanError.invalidArgument(all.isEmpty ? "Hostinger: keine Website im Konto" : "Hostinger: mehrere Websites, extra.website oder die Verbindungs-Einstellung Webhosting-Domain angeben: \(list)")
    }

    /// Website, die eine Subdomain trägt: übergeordnete Domain aus dem Namen.
    func parentWebsite(for fqdn: String) async throws -> Website {
        let all = try await websites()
        let name = Self.normalized(fqdn)
        let candidates = all.filter { $0.type != "subdomain" && name.hasSuffix("." + $0.domain.lowercased()) }
        guard let site = candidates.max(by: { $0.domain.count < $1.domain.count }) else {
            throw KastellanError.notFound("Hostinger: keine Website, zu der \(fqdn) gehört")
        }
        return site
    }
}

extension HostingerAdapter: SubdomainAdapter {
    public func listSubdomains(parent: String?) async throws -> [Subdomain] {
        let all = try await websites()
        let p = parent.map { Self.normalized($0) }
        return all.filter { $0.type == "subdomain" && (p == nil || $0.parent?.lowercased() == p! || $0.domain.lowercased().hasSuffix("." + p!)) }.map { site in
            Subdomain(ref: ref(site.domain), fqdn: site.domain, parent: site.parent ?? site.domain.split(separator: ".").dropFirst().joined(separator: "."),
                      targetPath: site.rootDirectory, extra: ["username": .string(site.username), "vhost_type": .string(site.type)])
        }.sorted { $0.fqdn < $1.fqdn }
    }

    public func createSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain {
        if redirect != nil { throw KastellanError.unsupported("Hostinger: Weiterleitungen für Subdomains laufen über die Website-Redirects, nicht über subdomain_create") }
        let site = try await website(extra["website"]?.stringValue) 
        let name = Self.normalized(fqdn)
        let label = name.hasSuffix("." + site.domain.lowercased()) ? String(name.dropLast(site.domain.count + 1)) : name
        let body = JSONValue.compactObject([
            "subdomain": .string(label),
            "directory": targetPath.map { .string($0) },
            "is_using_public_directory": extra["public_directory"] ?? .bool(true),
        ])
        try await client.post("/api/hosting/v1/accounts/\(site.username)/websites/\(site.domain)/subdomains", body: body)
        let created = try await client.list("/api/hosting/v1/accounts/\(site.username)/websites/\(site.domain)/subdomains")
            .first { $0.string("domain")?.lowercased() == "\(label).\(site.domain)".lowercased() || $0.string("subdomain") == label }
        return Subdomain(ref: ref("\(label).\(site.domain)"), fqdn: created?.string("domain") ?? "\(label).\(site.domain)", parent: site.domain,
                         targetPath: created?.string("root_directory") ?? targetPath, extra: ["username": .string(site.username)])
    }

    public func updateSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain {
        throw KastellanError.unsupported("Hostinger: Subdomains lassen sich nur anlegen und löschen, nicht ändern")
    }

    public func deleteSubdomain(fqdn: String) async throws {
        let site = try await parentWebsite(for: fqdn)
        let name = Self.normalized(fqdn)
        let label = String(name.dropLast(site.domain.count + 1))
        try await client.delete("/api/hosting/v1/accounts/\(site.username)/websites/\(site.domain)/subdomains/\(label)")
    }
}

extension HostingerAdapter: DatabaseAdapter {
    func database(_ item: JSONValue, username: String) -> Database {
        var extra = Self.extra(from: item, keys: ["domain", "permissions", "disk_usage_mb", "max_size_mb", "port", "created_at"])
        extra["username"] = .string(username)
        return Database(ref: ref(item.string("name") ?? ""), name: item.string("name") ?? "", engine: "mysql", host: item.string("host"),
                        users: [item.string("user")].compactMap { $0 }, comment: item.string("domain"), extra: extra)
    }

    public func listDatabases() async throws -> [Database] {
        var out: [Database] = []
        var seen = Set<String>()
        for site in try await websites() where seen.insert(site.username).inserted {
            out += try await client.list("/api/hosting/v1/accounts/\(site.username)/databases").map { database($0, username: site.username) }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// `comment` ist der Datenbankname (ohne Präfix); Nutzer heißt wie die Datenbank.
    public func createDatabase(password: String, comment: String?, allowedHosts: [String]) async throws -> Database {
        let site = try await website(nil)
        let base = (comment ?? "kastellan").lowercased().replacingOccurrences(of: "[^a-z0-9_]", with: "_", options: .regularExpression)
        try await client.post("/api/hosting/v1/accounts/\(site.username)/databases", body: .object([
            "name": .string(base), "user": .string(base), "password": .string(password), "website_domain": .string(site.domain),
        ]))
        let all = try await client.list("/api/hosting/v1/accounts/\(site.username)/databases")
        guard let created = all.first(where: { ($0.string("name") ?? "").hasSuffix(base) }) else {
            throw KastellanError.provider("Hostinger: Datenbank \(base) nach dem Anlegen nicht gefunden")
        }
        var db = database(created, username: site.username)
        if !allowedHosts.isEmpty {
            for host in allowedHosts {
                try await client.post("/api/hosting/v1/accounts/\(site.username)/databases/\(created.string("name") ?? base)/remote-connections", body: .object(["host": .string(host)]))
            }
            db.extra["allowed_hosts"] = .array(allowedHosts.map { .string($0) })
        }
        return db
    }

    public func updateDatabase(name: String, password: String?, comment: String?, allowedHosts: [String]?) async throws -> Database {
        guard let db = try await listDatabases().first(where: { $0.name == name }), let username = db.extra["username"]?.stringValue else {
            throw KastellanError.notFound("Datenbank \(name) bei Hostinger")
        }
        if let password {
            try await client.patch("/api/hosting/v1/accounts/\(username)/databases/\(name)/change-password", body: .object(["password": .string(password)]))
        }
        var result = db
        if let allowedHosts {
            for host in allowedHosts {
                try await client.post("/api/hosting/v1/accounts/\(username)/databases/\(name)/remote-connections", body: .object(["host": .string(host)]))
            }
            result.extra["allowed_hosts"] = .array(allowedHosts.map { .string($0) })
        }
        if comment != nil { result.extra["note"] = .string("Hostinger-Datenbanken haben keinen Kommentar; der Wert wurde ignoriert.") }
        return result
    }

    public func deleteDatabase(name: String) async throws {
        guard let db = try await listDatabases().first(where: { $0.name == name }), let username = db.extra["username"]?.stringValue else {
            throw KastellanError.notFound("Datenbank \(name) bei Hostinger")
        }
        try await client.delete("/api/hosting/v1/accounts/\(username)/databases/\(name)")
    }
}

extension HostingerAdapter: CronJobAdapter {
    func cronJob(_ item: JSONValue, username: String) -> CronJob {
        CronJob(ref: ref("\(username)/\(item.string("uid") ?? "")"), schedule: item.string("time") ?? "", url: nil, command: item.string("command"),
                comment: nil, active: true, extra: ["username": .string(username), "uid": .string(item.string("uid") ?? "")])
    }

    public func listCronJobs() async throws -> [CronJob] {
        var out: [CronJob] = []
        var seen = Set<String>()
        for site in try await websites() where seen.insert(site.username).inserted {
            out += try await client.list("/api/hosting/v1/accounts/\(site.username)/cron-jobs").map { cronJob($0, username: site.username) }
        }
        return out
    }

    public func createCronJob(schedule: String, url: String?, command: String?, comment: String?) async throws -> CronJob {
        let site = try await website(nil)
        let cmd: String
        if let command, !command.isEmpty { cmd = command }
        else if let url, !url.isEmpty { cmd = "curl -s '\(url)' > /dev/null" }
        else { throw KastellanError.invalidArgument("Cronjob braucht einen Befehl oder eine URL") }
        let created = try await client.post("/api/hosting/v1/accounts/\(site.username)/cron-jobs", body: .object(["time": .string(schedule), "command": .string(cmd)]))
        var job = cronJob(created, username: site.username)
        if let url, command == nil { job.url = url }
        if comment != nil { job.extra["note"] = .string("Hostinger-Cronjobs haben keinen Kommentar.") }
        return job
    }

    public func updateCronJob(providerRef: String, schedule: String?, url: String?, command: String?, comment: String?, active: Bool?) async throws -> CronJob {
        if active == false { throw KastellanError.unsupported("Hostinger-Cronjobs lassen sich nicht pausieren, nur löschen") }
        let (username, uid) = try Self.parseCronRef(providerRef)
        guard let current = try await client.list("/api/hosting/v1/accounts/\(username)/cron-jobs").first(where: { $0.string("uid") == uid }) else {
            throw KastellanError.notFound("Cronjob \(providerRef) bei Hostinger")
        }
        // Kein Update-Endpunkt: löschen und neu anlegen.
        let time = schedule ?? current.string("time") ?? ""
        let cmd = command ?? (url.map { "curl -s '\($0)' > /dev/null" }) ?? current.string("command") ?? ""
        try await client.delete("/api/hosting/v1/accounts/\(username)/cron-jobs/\(uid)")
        let created = try await client.post("/api/hosting/v1/accounts/\(username)/cron-jobs", body: .object(["time": .string(time), "command": .string(cmd)]))
        var job = cronJob(created, username: username)
        job.extra["note"] = .string("Hostinger kennt kein Cronjob-Update; der Job wurde gelöscht und neu angelegt (neue Kennung).")
        return job
    }

    public func deleteCronJob(providerRef: String) async throws {
        let (username, uid) = try Self.parseCronRef(providerRef)
        try await client.delete("/api/hosting/v1/accounts/\(username)/cron-jobs/\(uid)")
    }

    static func parseCronRef(_ providerRef: String) throws -> (String, String) {
        let parts = providerRef.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw KastellanError.invalidArgument("provider_ref \(providerRef) hat nicht die Form username/uid") }
        return (parts[0], parts[1])
    }
}

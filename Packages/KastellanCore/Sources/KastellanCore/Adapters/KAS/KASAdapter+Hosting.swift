import Foundation

// KAS-Funktionen für FTP-Zugänge, Datenbanken, Cronjobs, Zertifikate, Verzeichnisschutz und
// Subaccounts. FTP, Datenbank und Cronjob sind gegen echte Antworten abgebildet (Fixtures
// `get_ftpusers`, `get_databases`, `get_cronjobs`). Zertifikate leiten sich aus den SSL-Feldern
// von Domains und Subdomains ab (KAS hat kein `get_ssl`). Verzeichnisschutz und Subaccount haben
// kein Fixture, deren Feldnamen sind aus der KAS-Dokumentation geraten.

// MARK: - FTP

extension KASAdapter: FTPUserAdapter {
    static let ftpMapped: Set<String> = ["ftp_login", "ftp_path", "ftp_comment"]

    func ftpUser(from item: KASValue) -> FTPUser? {
        guard let login = item.string("ftp_login") else { return nil }
        var extra = Self.extra(from: item, excluding: Self.ftpMapped)
        if let comment = item.string("ftp_comment") { extra["comment"] = .string(comment) }
        return FTPUser(ref: ref(login), username: login, homePath: item.string("ftp_path"), status: nil, extra: extra)
    }

    public func listFTPUsers() async throws -> [FTPUser] {
        try await items("get_ftpusers").compactMap(ftpUser(from:))
    }

    func findFTPUser(username: String) async throws -> FTPUser? {
        try await listFTPUsers().first { $0.username.lowercased() == username.lowercased() }
    }

    /// KAS vergibt den Login selbst (`f0…`), ein Wunschname ist nicht möglich.
    public func createFTPUser(username: String?, password: String, homePath: String, comment: String?) async throws -> FTPUser {
        if let username, !username.isEmpty {
            throw KastellanError.unsupported("KAS vergibt FTP-Logins selbst, ein Wunschname (\(username)) ist nicht möglich")
        }
        guard !password.isEmpty else { throw KastellanError.invalidArgument("Passwort ist leer") }
        var params = ["ftp_password": password, "ftp_path": homePath]
        if let comment { params["ftp_comment"] = comment }
        let response = try await call("add_ftpuser", params)
        let login = response.returnInfo.string ?? ""
        if !login.isEmpty, let user = try await findFTPUser(username: login) { return user }
        var extra: Extra = [:]
        if let comment { extra["comment"] = .string(comment) }
        return FTPUser(ref: ref(login), username: login, homePath: homePath, extra: extra)
    }

    public func updateFTPUser(username: String, password: String?, homePath: String?, comment: String?) async throws -> FTPUser {
        var params = ["ftp_login": username]
        if let password, !password.isEmpty { params["ftp_password"] = password }
        if let homePath { params["ftp_path"] = homePath }
        if let comment { params["ftp_comment"] = comment }
        try await call("update_ftpuser", params)
        guard let user = try await findFTPUser(username: username) else {
            throw KastellanError.notFound("FTP-Zugang \(username)")
        }
        return user
    }

    public func deleteFTPUser(username: String) async throws {
        try await call("delete_ftpuser", ["ftp_login": username])
    }
}

// MARK: - Datenbank

extension KASAdapter: DatabaseAdapter {
    static let databaseMapped: Set<String> = ["database_name", "database_login", "database_comment", "database_allowed_hosts", "used_database_space"]

    func database(from item: KASValue) -> Database? {
        guard let name = item.string("database_name") ?? item.string("database_login") else { return nil }
        let login = item.string("database_login") ?? name
        var extra = Self.extra(from: item, excluding: Self.databaseMapped)
        extra["allowed_hosts"] = .array(Self.list(item.string("database_allowed_hosts")).map(JSONValue.string))
        if let used = item.double("used_database_space") { extra["used_mb"] = .int(Int(used.rounded())) }
        return Database(ref: ref(login), name: name, engine: "mysql", host: nil, users: [login],
                        comment: item.string("database_comment"), extra: extra)
    }

    public func listDatabases() async throws -> [Database] {
        try await items("get_databases").compactMap(database(from:))
    }

    func findDatabase(name: String) async throws -> Database? {
        try await listDatabases().first { $0.name.lowercased() == name.lowercased() || $0.ref.providerRef.lowercased() == name.lowercased() }
    }

    public func createDatabase(password: String, comment: String?, allowedHosts: [String]) async throws -> Database {
        guard !password.isEmpty else { throw KastellanError.invalidArgument("Passwort ist leer") }
        var params = ["database_password": password]
        if let comment { params["database_comment"] = comment }
        if !allowedHosts.isEmpty { params["database_allowed_hosts"] = allowedHosts.joined(separator: ",") }
        let response = try await call("add_database", params)
        let login = response.returnInfo.string ?? ""
        if !login.isEmpty, let db = try await findDatabase(name: login) { return db }
        return Database(ref: ref(login), name: login, users: login.isEmpty ? [] : [login], comment: comment,
                        extra: ["allowed_hosts": .array(allowedHosts.map(JSONValue.string))])
    }

    public func updateDatabase(name: String, password: String?, comment: String?, allowedHosts: [String]?) async throws -> Database {
        var params = ["database_login": name]
        if let password, !password.isEmpty { params["database_password"] = password }
        if let comment { params["database_comment"] = comment }
        if let allowedHosts { params["database_allowed_hosts"] = allowedHosts.joined(separator: ",") }
        try await call("update_database", params)
        guard let db = try await findDatabase(name: name) else {
            throw KastellanError.notFound("Datenbank \(name)")
        }
        return db
    }

    public func deleteDatabase(name: String) async throws {
        try await call("delete_database", ["database_login": name])
    }
}

// MARK: - Cronjob

extension KASAdapter: CronJobAdapter {
    static let cronMapped: Set<String> = ["cronjob_id", "cronjob_comment", "protocol", "http_url", "minute", "hour", "day_of_month", "month", "day_of_week", "is_active"]
    static let cronFields = ["minute", "hour", "day_of_month", "month", "day_of_week"]

    func cronJob(from item: KASValue) -> CronJob? {
        guard let id = item.string("cronjob_id") else { return nil }
        let schedule = Self.cronFields.map { item.string($0) ?? "*" }.joined(separator: " ")
        var url: String?
        if let host = item.string("http_url") {
            url = "\(item.string("protocol") ?? "https")://\(host)"
        }
        return CronJob(
            ref: ref(id),
            schedule: schedule,
            url: url,
            command: nil,
            comment: item.string("cronjob_comment"),
            active: item.bool("is_active") ?? true,
            extra: Self.extra(from: item, excluding: Self.cronMapped)
        )
    }

    /// `m h dom mon dow` in die fünf KAS-Parameter.
    static func scheduleParams(_ schedule: String) throws -> [String: String] {
        let parts = schedule.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 5 else {
            throw KastellanError.invalidArgument("Zeitplan braucht fünf Felder (Minute Stunde Tag Monat Wochentag): \(schedule)")
        }
        return Dictionary(uniqueKeysWithValues: zip(cronFields, parts))
    }

    /// `https://host/pfad` in `protocol` und `http_url`.
    static func urlParams(_ url: String) throws -> [String: String] {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: "://") else {
            throw KastellanError.invalidArgument("URL braucht ein Schema (http:// oder https://): \(url)")
        }
        let proto = String(trimmed[..<range.lowerBound]).lowercased()
        let rest = String(trimmed[range.upperBound...])
        guard proto == "http" || proto == "https", !rest.isEmpty else {
            throw KastellanError.invalidArgument("KAS-Cronjobs rufen nur http- oder https-URLs auf: \(url)")
        }
        return ["protocol": proto, "http_url": rest]
    }

    public func listCronJobs() async throws -> [CronJob] {
        try await items("get_cronjobs").compactMap(cronJob(from:))
    }

    func findCronJob(providerRef: String) async throws -> CronJob? {
        try await listCronJobs().first { $0.ref.providerRef == providerRef }
    }

    public func createCronJob(schedule: String, url: String?, command: String?, comment: String?) async throws -> CronJob {
        if let command, !command.isEmpty {
            throw KastellanError.unsupported("KAS-Cronjobs können nur URLs aufrufen, keine Befehle")
        }
        guard let url, !url.isEmpty else { throw KastellanError.invalidArgument("Cronjob braucht eine URL") }
        var params = try Self.scheduleParams(schedule)
        params.merge(try Self.urlParams(url)) { _, new in new }
        if let comment { params["cronjob_comment"] = comment }
        let response = try await call("add_cronjob", params)
        let id = response.returnInfo.string ?? ""
        if !id.isEmpty, let job = try await findCronJob(providerRef: id) { return job }
        let jobs = try await listCronJobs()
        if let job = jobs.last(where: { $0.url == url && $0.schedule == schedule }) { return job }
        return CronJob(ref: ref(id), schedule: schedule, url: url, comment: comment)
    }

    public func updateCronJob(providerRef: String, schedule: String?, url: String?, command: String?, comment: String?, active: Bool?) async throws -> CronJob {
        if let command, !command.isEmpty {
            throw KastellanError.unsupported("KAS-Cronjobs können nur URLs aufrufen, keine Befehle")
        }
        // KAS will bei update_cronjob den vollständigen Satz, daher den aktuellen Stand nachlesen.
        guard let current = try await findCronJob(providerRef: providerRef) else {
            throw KastellanError.notFound("Cronjob \(providerRef)")
        }
        var params = try Self.scheduleParams(schedule ?? current.schedule)
        if let url = url ?? current.url { params.merge(try Self.urlParams(url)) { _, new in new } }
        params["cronjob_id"] = providerRef
        params["cronjob_comment"] = comment ?? current.comment ?? ""
        params["is_active"] = Self.yn(active ?? current.active)
        try await call("update_cronjob", params)
        return try await findCronJob(providerRef: providerRef) ?? current
    }

    public func deleteCronJob(providerRef: String) async throws {
        try await call("delete_cronjob", ["cronjob_id": providerRef])
    }
}

// MARK: - Zertifikat

extension KASAdapter: CertificateAdapter {
    static let certificateFields: Set<String> = [
        "ssl_certificate_sni", "ssl_certificate_ip", "ssl_certificate_sni_is_active", "ssl_certificate_sni_force_https",
        "ssl_certificate_sni_hsts_max_age", "ssl_certificate_sni_type", "ssl_certificate_sni_csr", "ssl_certificate_sni_crt",
        "ssl_certificate_sni_bundle", "ssl_certificate_sni_chainfile", "ssl_proxy",
    ]

    /// Zertifikat aus den SSL-Feldern einer Domain oder Subdomain, `nil` ohne Zertifikat.
    func certificate(from item: KASValue, hostname: String) -> Certificate? {
        let sni = item.bool("ssl_certificate_sni") ?? false
        let ip = item.bool("ssl_certificate_ip") ?? false
        guard sni || ip else { return nil }
        var extra: Extra = [:]
        for key in Self.certificateFields where !Self.isSecretKey(key) {
            if let value = item[key] { extra[key] = value.jsonValue }
        }
        extra["kind"] = .string(sni ? "sni" : "ip")
        if let active = item.bool("ssl_certificate_sni_is_active") { extra["active"] = .bool(active) }
        if let hsts = item.int("ssl_certificate_sni_hsts_max_age") { extra["hsts_max_age"] = .int(hsts) }
        return Certificate(
            ref: ref(hostname),
            hostname: hostname,
            issuer: nil,
            validUntil: nil,
            autoRenew: nil,
            forceHTTPS: item.bool("ssl_certificate_sni_force_https"),
            extra: extra
        )
    }

    public func listCertificates() async throws -> [Certificate] {
        var result: [Certificate] = []
        for item in try await items("get_domains") {
            if let host = item.string("domain_name"), let cert = certificate(from: item, hostname: host) { result.append(cert) }
        }
        for item in try await items("get_subdomains") {
            if let host = item.string("subdomain_name"), let cert = certificate(from: item, hostname: host) { result.append(cert) }
        }
        return result
    }

    /// `update_ssl` (Upload und HTTPS-Zwang). Parametername `ssl_certificate_force_https` ist nicht durch ein Fixture belegt.
    public func updateCertificate(hostname: String, forceHTTPS: Bool?, extra: Extra) async throws -> Certificate {
        var params = Self.params(from: extra)
        params["hostname"] = hostname
        if let forceHTTPS { params["ssl_certificate_force_https"] = Self.yn(forceHTTPS) }
        try await call("update_ssl", params)
        if let cert = try await listCertificates().first(where: { $0.hostname.lowercased() == hostname.lowercased() }) { return cert }
        return Certificate(ref: ref(hostname), hostname: hostname, forceHTTPS: forceHTTPS)
    }
}

// MARK: - Verzeichnisschutz (ohne Fixture, Feldnamen geraten)

extension KASAdapter: DirectoryProtectionAdapter {
    static let directoryMapped: Set<String> = ["directory_path", "directory_user", "directory_authname"]

    public func listDirectoryProtections() async throws -> [DirectoryProtection] {
        var byPath: [String: DirectoryProtection] = [:]
        var order: [String] = []
        for item in try await items("get_directoryprotection") {
            guard let path = item.string("directory_path") else { continue }
            let user = item.string("directory_user")
            if var existing = byPath[path] {
                if let user, !existing.users.contains(user) { existing.users.append(user) }
                byPath[path] = existing
            } else {
                order.append(path)
                byPath[path] = DirectoryProtection(
                    ref: ref(path), path: path, users: user.map { [$0] } ?? [],
                    realm: item.string("directory_authname"),
                    extra: Self.extra(from: item, excluding: Self.directoryMapped)
                )
            }
        }
        return order.compactMap { byPath[$0] }
    }

    public func createDirectoryProtection(path: String, username: String, password: String, realm: String?) async throws -> DirectoryProtection {
        guard !password.isEmpty else { throw KastellanError.invalidArgument("Passwort ist leer") }
        var params = ["directory_path": path, "directory_user": username, "directory_password": password]
        if let realm { params["directory_authname"] = realm }
        try await call("add_directoryprotection", params)
        if let dp = try await listDirectoryProtections().first(where: { $0.path == path }) { return dp }
        return DirectoryProtection(ref: ref(path), path: path, users: [username], realm: realm)
    }

    public func deleteDirectoryProtection(path: String, username: String?) async throws {
        var params = ["directory_path": path]
        if let username, !username.isEmpty { params["directory_user"] = username }
        try await call("delete_directoryprotection", params)
    }
}

// MARK: - Subaccount (ohne Fixture, Feldnamen geraten)

extension KASAdapter: SubaccountAdapter {
    static let subaccountMapped: Set<String> = ["account_login", "account_comment"]

    func subaccount(from item: KASValue) -> Subaccount? {
        guard let login = item.string("account_login") else { return nil }
        return Subaccount(ref: ref(login), login: login, comment: item.string("account_comment"),
                          extra: Self.extra(from: item, excluding: Self.subaccountMapped))
    }

    public func listSubaccounts() async throws -> [Subaccount] {
        try await items("get_accounts").compactMap(subaccount(from:))
    }

    public func createSubaccount(password: String, comment: String?, extra: Extra) async throws -> Subaccount {
        guard !password.isEmpty else { throw KastellanError.invalidArgument("Passwort ist leer") }
        var params = Self.params(from: extra)
        params["account_password"] = password
        if let comment { params["account_comment"] = comment }
        let response = try await call("add_account", params)
        let login = response.returnInfo.string ?? ""
        if !login.isEmpty, let acc = try await listSubaccounts().first(where: { $0.login == login }) { return acc }
        return Subaccount(ref: ref(login), login: login, comment: comment)
    }

    public func deleteSubaccount(login: String) async throws {
        try await call("delete_account", ["account_login": login])
    }
}

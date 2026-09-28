import Foundation

// Cronjobs, Verzeichnisschutz und Zertifikate bei hosting.de. Alles hängt an Voll-Objekt-Updates:
// Cronjobs sind eine Liste ohne IDs im Webspace (`webspaceUpdate`), Verzeichnisschutz sind
// `httpUsers`, `setHttpUserPasswords` und `locations[].restrictToHttpUsers` am VHost
// (`vhostUpdate`), Zertifikate stehen in `vhost.sslSettings` (Let's Encrypt über
// `vhostActivateSsl`) und im ssl-Dienst (`certificatesFind`, Beta). Beim Praxistest prüfen:
// Werte für `locationType`/`matchType` (Doku-Beispiele nutzen `generic`/`default`, die
// Feldbeschreibung `location`/`directory`), ob Cronjobs in `webspaceUpdate` komplett ersetzt
// werden, ob der ssl-Dienst mit dem Key erreichbar ist.

// MARK: - Cronjobs

extension HostingDeAdapter: CronJobAdapter {
    static let cronIntervals = ["1min", "5min", "10min", "15min", "30min", "1hour", "2hour", "3hour", "4hour", "6hour", "12hour", "daily", "weekly", "monthly"]
    static let cronDayparts = ["1-5", "5-9", "9-13", "13-17", "17-21", "21-1"]
    static let cronWeekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// Zeitplan von hosting.de (`schedule`, `daypart`, `weekday`, `dayOfMonth`) als lesbarer Text.
    static func scheduleText(_ job: JSONValue) -> String {
        var s = job.string("schedule") ?? "?"
        if let part = job.string("daypart") { s += " \(part)h" }
        if let day = job.string("weekday") { s += " \(day)" }
        if let dom = job.int("dayOfMonth") { s += " day \(dom)" }
        return s
    }

    /// Kastellan-Zeitplan (Cron-Ausdruck oder hosting.de-Intervall mit Zusätzen) in die Felder von hosting.de.
    static func scheduleFields(_ schedule: String) throws -> [String: JSONValue] {
        let text = schedule.trimmingCharacters(in: .whitespaces)
        let words = text.split(separator: " ").map(String.init)
        // Direkt: "daily 9-13", "weekly 1-5 mon", "monthly 5-9 15", "5min"
        if let first = words.first, cronIntervals.contains(first) {
            var f: [String: JSONValue] = ["schedule": .string(first)]
            for w in words.dropFirst() {
                if cronDayparts.contains(w) { f["daypart"] = .string(w) }
                else if cronWeekdays.contains(w.lowercased()) { f["weekday"] = .string(w.lowercased()) }
                else if let d = Int(w), (1...31).contains(d) { f["dayOfMonth"] = .int(d) }
                else { throw KastellanError.invalidArgument("Zeitplan-Zusatz \(w) unbekannt (Tageszeit \(cronDayparts.joined(separator: ", ")), Wochentag, Tag im Monat)") }
            }
            if ["daily", "weekly", "monthly"].contains(first), f["daypart"] == nil { f["daypart"] = .string("1-5") }
            if first == "weekly", f["weekday"] == nil { f["weekday"] = .string("mon") }
            if first == "monthly", f["dayOfMonth"] == nil { f["dayOfMonth"] = .int(1) }
            return f
        }
        guard words.count == 5 else {
            throw KastellanError.invalidArgument("Zeitplan als Cron-Ausdruck (m h dom mon dow) oder hosting.de-Intervall (\(cronIntervals.joined(separator: ", "))): \(schedule)")
        }
        let (minute, hour, dom, month, dow) = (words[0], words[1], words[2], words[3], words[4])
        guard month == "*" else { throw KastellanError.invalidArgument("hosting.de-Cronjobs kennen keine Monatsangabe: \(schedule)") }
        if hour == "*", dom == "*", dow == "*" {
            if minute == "*" { return ["schedule": .string("1min")] }
            if minute.hasPrefix("*/"), let n = Int(minute.dropFirst(2)), cronIntervals.contains("\(n)min") { return ["schedule": .string("\(n)min")] }
            if minute == "0" { return ["schedule": .string("1hour")] }
        }
        if dom == "*", dow == "*", hour.hasPrefix("*/"), let n = Int(hour.dropFirst(2)), cronIntervals.contains("\(n)hour") {
            return ["schedule": .string("\(n)hour")]
        }
        guard let h = Int(hour) else {
            throw KastellanError.invalidArgument("Zeitplan \(schedule) passt auf kein hosting.de-Intervall (feste Stunde oder */N nötig)")
        }
        let daypart = cronDayparts.first { part in
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            guard bounds.count == 2 else { return false }
            return bounds[0] < bounds[1] ? (bounds[0]..<bounds[1]).contains(h) : (h >= bounds[0] || h < bounds[1])
        } ?? "1-5"
        if dom == "*", dow == "*" { return ["schedule": .string("daily"), "daypart": .string(daypart)] }
        if dom == "*", let d = Int(dow), (0...7).contains(d) {
            return ["schedule": .string("weekly"), "daypart": .string(daypart), "weekday": .string(cronWeekdays[d % 7])]
        }
        if dom == "*", cronWeekdays.contains(dow.lowercased()) {
            return ["schedule": .string("weekly"), "daypart": .string(daypart), "weekday": .string(dow.lowercased())]
        }
        if dow == "*", let d = Int(dom), (1...31).contains(d) {
            return ["schedule": .string("monthly"), "daypart": .string(daypart), "dayOfMonth": .int(d)]
        }
        throw KastellanError.invalidArgument("Zeitplan \(schedule) passt auf kein hosting.de-Intervall")
    }

    func cronJob(webspace: JSONValue, index: Int, job: JSONValue) -> CronJob {
        var extra = Self.extra(from: job, keys: ["type", "script", "parameters", "interpreterVersion", "schedule", "daypart", "weekday", "dayOfMonth"])
        extra["webspace_id"] = .string(webspace.string("id") ?? "")
        let type = job.string("type") ?? ""
        return CronJob(ref: ref("\(webspace.string("id") ?? "")/\(index)"), schedule: Self.scheduleText(job),
                       url: type == "url" ? job.string("url") : nil,
                       command: type == "url" ? nil : job.string("script"),
                       comment: job.string("comments"), active: true, extra: extra)
    }

    static func cronEntry(schedule: String, url: String?, command: String?, comment: String?, existing: JSONValue? = nil) throws -> JSONValue {
        var o = existing?.objectValue ?? [:]
        let fields = try scheduleFields(schedule)
        // Beim Wechsel des Intervalls alte Zusätze nicht stehen lassen.
        for key in ["schedule", "daypart", "weekday", "dayOfMonth"] { o.removeValue(forKey: key) }
        for (k, v) in fields { o[k] = v }
        if let url, !url.isEmpty {
            o["type"] = .string("url"); o["url"] = .string(url); o.removeValue(forKey: "script")
        } else if let command, !command.isEmpty {
            let script = command.trimmingCharacters(in: .whitespaces)
            guard script.hasPrefix("data/") || script.hasPrefix("html/") else {
                throw KastellanError.invalidArgument("hosting.de-Cronjobs führen Skripte relativ zum Webspace aus, Pfad muss mit data/ oder html/ beginnen: \(script)")
            }
            o["type"] = .string(script.lowercased().hasSuffix(".php") ? "php" : "bash"); o["script"] = .string(script); o.removeValue(forKey: "url")
        } else if existing == nil {
            throw KastellanError.invalidArgument("Cronjob braucht eine URL oder ein Skript")
        }
        if let comment { o["comments"] = .string(comment) }
        return .object(o)
    }

    public func listCronJobs() async throws -> [CronJob] {
        var jobs: [CronJob] = []
        for ws in try await webspaces() {
            for (i, job) in ws.array("cronJobs").enumerated() { jobs.append(cronJob(webspace: ws, index: i, job: job)) }
        }
        return jobs
    }

    public func createCronJob(schedule: String, url: String?, command: String?, comment: String?) async throws -> CronJob {
        let webspace = try await singleWebspace()
        var jobs = webspace.array("cronJobs")
        jobs.append(try Self.cronEntry(schedule: schedule, url: url, command: command, comment: comment))
        let updated = try await writeWebspace(withCronJobs: jobs, webspace)
        let list = updated.array("cronJobs")
        return cronJob(webspace: updated, index: list.count - 1, job: list.last ?? jobs.last!)
    }

    public func updateCronJob(providerRef: String, schedule: String?, url: String?, command: String?, comment: String?, active: Bool?) async throws -> CronJob {
        if active == false { throw KastellanError.unsupported("hosting.de-Cronjobs lassen sich nicht pausieren, nur löschen") }
        let (webspace, index) = try await cronLocation(providerRef)
        var jobs = webspace.array("cronJobs")
        let current = jobs[index]
        let merged = try Self.cronEntry(schedule: schedule ?? Self.scheduleText(current), url: url, command: command, comment: comment, existing: current)
        jobs[index] = merged
        let updated = try await writeWebspace(withCronJobs: jobs, webspace)
        return cronJob(webspace: updated, index: index, job: updated.array("cronJobs").indices.contains(index) ? updated.array("cronJobs")[index] : merged)
    }

    public func deleteCronJob(providerRef: String) async throws {
        let (webspace, index) = try await cronLocation(providerRef)
        var jobs = webspace.array("cronJobs")
        jobs.remove(at: index)
        _ = try await writeWebspace(withCronJobs: jobs, webspace)
    }

    func cronLocation(_ providerRef: String) async throws -> (JSONValue, Int) {
        let parts = providerRef.split(separator: "/").map(String.init)
        guard parts.count == 2, let index = Int(parts[1]) else {
            throw KastellanError.invalidArgument("provider_ref \(providerRef) hat nicht die Form webspace/index")
        }
        guard let ws = try await client.findPage("webhosting", "webspacesFind", filter: .equal("WebspaceId", parts[0]), limit: 1).data.first,
              ws.array("cronJobs").indices.contains(index) else {
            throw KastellanError.notFound("Cronjob \(providerRef) bei hosting.de")
        }
        return (ws, index)
    }

    func writeWebspace(withCronJobs jobs: [JSONValue], _ webspace: JSONValue) async throws -> JSONValue {
        var object = webspace.objectValue ?? [:]
        object["cronJobs"] = .array(jobs)
        return try await writeWebspace(.object(object), accesses: webspace.array("accesses"))
    }
}

// MARK: - Verzeichnisschutz

extension HostingDeAdapter: DirectoryProtectionAdapter {
    /// Pfadform `domain/verzeichnis`: VHost und Location.
    static func splitProtectionPath(_ path: String) throws -> (domain: String, match: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.firstIndex(of: "/") else {
            guard trimmed.contains(".") else { throw KastellanError.invalidArgument("Pfad als domain/verzeichnis angeben, z. B. app.example.com/admin") }
            return (normalized(trimmed), "/")
        }
        let domain = String(trimmed[..<slash])
        guard domain.contains(".") else { throw KastellanError.invalidArgument("Pfad als domain/verzeichnis angeben, z. B. app.example.com/admin") }
        var match = String(trimmed[slash...])
        if match.count > 1, match.hasSuffix("/") { match.removeLast() }
        return (normalized(domain), match.isEmpty ? "/" : match)
    }

    func protections(vhost: JSONValue) -> [DirectoryProtection] {
        let domain = vhost.string("domainName") ?? ""
        return vhost.array("locations").compactMap { loc in
            let users = loc.strings("restrictToHttpUsers")
            guard !users.isEmpty else { return nil }
            let match = loc.string("matchString") ?? "/"
            var extra: Extra = ["vhost_id": .string(vhost.string("id") ?? ""), "domain": .string(domain), "matchType": .string(loc.string("matchType") ?? "")]
            if let t = loc.string("locationType") { extra["locationType"] = .string(t) }
            let path = domain + (match.hasPrefix("/") ? match : "/" + match)
            return DirectoryProtection(ref: ref("\(vhost.string("id") ?? "")\(match)"), path: path, users: users, realm: nil, extra: extra)
        }
    }

    public func listDirectoryProtections() async throws -> [DirectoryProtection] {
        try await client.findAll("webhosting", "vhostsFind").flatMap { protections(vhost: $0) }.sorted { $0.path < $1.path }
    }

    public func createDirectoryProtection(path: String, username: String, password: String, realm: String?) async throws -> DirectoryProtection {
        let (domain, match) = try Self.splitProtectionPath(path)
        let vhost = try await vhost(named: domain)
        var object = vhost.objectValue ?? [:]
        var users = vhost.strings("httpUsers")
        if !users.contains(username) { users.append(username) }
        object["httpUsers"] = .array(users.map { .string($0) })
        object["setHttpUserPasswords"] = .array([.object(["name": .string(username), "password": .string(password)])])
        var locations = vhost.array("locations")
        if let idx = locations.firstIndex(where: { $0.string("matchString") == match && $0.string("locationType") != "redirect" }) {
            var loc = locations[idx].objectValue ?? [:]
            var restricted = locations[idx].strings("restrictToHttpUsers")
            if !restricted.contains(username) { restricted.append(username) }
            loc["restrictToHttpUsers"] = .array(restricted.map { .string($0) })
            locations[idx] = .object(loc)
        } else {
            locations.append(.object([
                "locationType": .string("location"), "matchType": .string("directory"), "matchString": .string(match),
                "phpEnabled": .bool(true), "directoryListingEnabled": .bool(false), "restrictToHttpUsers": .array([.string(username)]),
            ]))
        }
        object["locations"] = .array(locations)
        let updated = try await writeVHost(.object(object), what: "VHost \(domain)")
        guard let result = protections(vhost: updated).first(where: { $0.path == domain + match }) else {
            throw KastellanError.provider("hosting.de: Verzeichnisschutz \(path) fehlt nach vhostUpdate")
        }
        return result
    }

    public func deleteDirectoryProtection(path: String, username: String?) async throws {
        let (domain, match) = try Self.splitProtectionPath(path)
        let vhost = try await vhost(named: domain)
        var object = vhost.objectValue ?? [:]
        var locations = vhost.array("locations")
        guard let idx = locations.firstIndex(where: { $0.string("matchString") == match && !$0.strings("restrictToHttpUsers").isEmpty }) else {
            throw KastellanError.notFound("Verzeichnisschutz \(path) bei hosting.de")
        }
        var loc = locations[idx].objectValue ?? [:]
        var restricted = locations[idx].strings("restrictToHttpUsers")
        if let username {
            guard restricted.contains(username) else { throw KastellanError.notFound("Nutzer \(username) im Verzeichnisschutz \(path)") }
            restricted.removeAll { $0 == username }
        } else {
            restricted = []
        }
        loc["restrictToHttpUsers"] = .array(restricted.map { .string($0) })
        locations[idx] = .object(loc)
        object["locations"] = .array(locations)
        // HTTP-Nutzer entfernen, die keine Location mehr schützen.
        let stillUsed = Set(locations.flatMap { $0.strings("restrictToHttpUsers") })
        object["httpUsers"] = .array(vhost.strings("httpUsers").filter { stillUsed.contains($0) }.map { .string($0) })
        _ = try await writeVHost(.object(object), what: "VHost \(domain)")
    }

    /// VHost ohne Nur-Lese-Felder zurückschreiben und auf `active` warten.
    func writeVHost(_ vhost: JSONValue, method: String = "vhostUpdate", what: String) async throws -> JSONValue {
        var object = vhost.objectValue ?? [:]
        for key in ["addDate", "lastChangeDate", "systemAlias", "status", "blocked", "restorableUntil", "deletionScheduledFor", "accountId", "domainNameUnicode"] {
            object.removeValue(forKey: key)
        }
        let result = try await client.call("webhosting", method, ["vhost": .object(object)])
        var updated = result.response
        if result.pending || updated.string("status") != "active", let id = updated.string("id") ?? object["id"]?.stringValue {
            updated = try await waitForVHost(id, what: what)
        }
        return updated
    }
}

// MARK: - Zertifikate

extension HostingDeAdapter: CertificateAdapter {
    static let letsEncryptProduct = "ssl-letsencrypt-dv-3m"

    func certificate(vhost: JSONValue) -> Certificate? {
        guard let ssl = vhost["sslSettings"], ssl != .null else { return nil }
        let managed = ssl.string("managedSslProductCode")
        var extra = Self.extra(from: ssl, keys: ["profile", "managedSslProductCode", "managedSslStatus", "hstsMaxAge", "hstsIncludeSubdomains", "hstsAllowPreload"])
        extra["vhost_id"] = .string(vhost.string("id") ?? "")
        extra["source"] = .string("vhost")
        let issuer: String? = managed.map { $0.contains("letsencrypt") ? "Let's Encrypt" : $0 } ?? (ssl.string("certificates") != nil ? "eigenes Zertifikat" : nil)
        return Certificate(ref: ref(vhost.string("id") ?? ""), hostname: vhost.string("domainName") ?? "", issuer: issuer,
                           validUntil: nil, autoRenew: managed != nil, forceHTTPS: (ssl.int("hstsMaxAge") ?? 0) > 0 ? true : nil, extra: extra)
    }

    func certificate(order item: JSONValue) -> Certificate {
        var extra = Self.extra(from: item, keys: ["id", "status", "orderStatus", "productCode", "validationLevel", "serialNumber", "additionalDomainNames", "startDate"])
        extra["source"] = .string("ssl")
        return Certificate(ref: ref("ssl/\(item.string("id") ?? "")"), hostname: item.string("commonName") ?? "", issuer: item.string("brand"),
                           validUntil: HostingDeDates.date(item.string("endDate")), autoRenew: nil, forceHTTPS: nil, extra: extra)
    }

    public func listCertificates() async throws -> [Certificate] {
        var certs = try await client.findAll("webhosting", "vhostsFind").compactMap { certificate(vhost: $0) }
        // Der ssl-Dienst ist Beta; Fehler dort blockieren die VHost-Liste nicht.
        if let orders = try? await client.findAll("ssl", "certificatesFind") {
            certs += orders.map { certificate(order: $0) }
        }
        return certs.sorted { $0.hostname < $1.hostname }
    }

    /// Let's Encrypt aktivieren (`extra.lets_encrypt` oder ohne bestehendes Zertifikat), HSTS über
    /// `extra.hsts_max_age`. `force_https` kennt hosting.de nicht als Schalter; HSTS ist die Näherung.
    public func updateCertificate(hostname: String, forceHTTPS: Bool?, extra: Extra) async throws -> Certificate {
        let vhost = try await vhost(named: Self.normalized(hostname))
        var object = vhost.objectValue ?? [:]
        var ssl = vhost["sslSettings"]?.objectValue ?? [:]
        let hasCertificate = vhost["sslSettings"] != nil && vhost["sslSettings"] != .null
        let wantsLE = extra["lets_encrypt"]?.boolValue ?? !hasCertificate
        var method = "vhostUpdate"
        if wantsLE, ssl["managedSslProductCode"] == nil {
            ssl["profile"] = ssl["profile"] ?? .string("modern")
            ssl["managedSslProductCode"] = .string(extra["product_code"]?.stringValue ?? Self.letsEncryptProduct)
            method = "vhostActivateSsl"
        }
        if let profile = extra["ssl_profile"] { ssl["profile"] = profile }
        if let maxAge = extra["hsts_max_age"]?.intValue { ssl["hstsMaxAge"] = .int(maxAge) }
        else if forceHTTPS == true, (ssl["hstsMaxAge"]?.intValue ?? 0) == 0 { ssl["hstsMaxAge"] = .int(31_536_000) }
        else if forceHTTPS == false { ssl["hstsMaxAge"] = .int(0) }
        if let sub = extra["hsts_include_subdomains"] { ssl["hstsIncludeSubdomains"] = sub }
        object["sslSettings"] = .object(ssl)
        let updated = try await writeVHost(.object(object), method: method, what: "VHost \(hostname)")
        guard var cert = certificate(vhost: updated) else {
            throw KastellanError.provider("hosting.de: VHost \(hostname) hat nach \(method) keine SSL-Einstellungen")
        }
        if forceHTTPS != nil {
            cert.extra["note"] = .string("hosting.de hat keinen HTTPS-Zwang-Schalter; force_https setzt HSTS (hstsMaxAge).")
        }
        return cert
    }
}

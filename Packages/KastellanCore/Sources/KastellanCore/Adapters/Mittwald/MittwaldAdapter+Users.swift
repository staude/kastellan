import Foundation

// SSH- und SFTP-Nutzer, MySQL-Datenbanken mit Nutzern und Cronjobs bei Mittwald, schreibend.
// SSH/SFTP: `POST /projects/{id}/ssh-users` bzw. `/sftp-users` mit `authentication`
// (`{password}` oder `{publicKeys[{key, comment}]}`), `userName` vergibt Mittwald, SFTP braucht
// `directories` und `accessLevel`. MySQL: `POST /projects/{id}/mysql-databases` legt Datenbank und
// Hauptnutzer zusammen an (asynchron, Status pollen), Passwort über `PATCH /mysql-users/{id}`.
// Cronjobs: `POST /projects/{id}/cronjobs` mit Ziel App-Installation (URL oder Interpreter+Pfad).

extension MittwaldAdapter {
    static let defaultCronTimeout = 600

    func sshUserObject(named userName: String) async throws -> JSONValue {
        for pid in try await projectIDs() {
            if let u = try await client.list("/projects/\(pid)/ssh-users").first(where: { $0.string("userName") == userName }) { return u }
        }
        throw KastellanError.notFound("SSH-Nutzer \(userName) bei Mittwald")
    }

    func sftpUserObject(named userName: String) async throws -> JSONValue {
        for pid in try await projectIDs() {
            if let u = try await client.list("/projects/\(pid)/sftp-users").first(where: { $0.string("userName") == userName }) { return u }
        }
        throw KastellanError.notFound("SFTP-Nutzer \(userName) bei Mittwald")
    }

    func databaseObject(named name: String) async throws -> JSONValue {
        for pid in try await projectIDs() {
            if let db = try await client.list("/projects/\(pid)/mysql-databases").first(where: { $0.string("name") == name || $0.string("id") == name || $0.string("description") == name }) { return db }
        }
        throw KastellanError.notFound("Datenbank \(name) bei Mittwald")
    }

    /// Neueste verfügbare MySQL-Version (`GET /mysql-versions`), Antwort als `{number}` oder String.
    func latestMySQLVersion() async throws -> String {
        let versions = try await client.get("/mysql-versions").arrayValue ?? []
        let numbers = versions.filter { $0.bool("disabled") != true }.compactMap { $0.stringValue ?? $0.string("number") ?? $0.string("version") }
        guard let latest = numbers.sorted(by: { a, b in a.compare(b, options: .numeric) == .orderedAscending }).last else {
            throw KastellanError.provider("Mittwald: keine MySQL-Version verfügbar")
        }
        return latest
    }

    /// `interpreter pfad parameter` oder `pfad parameter` in das Cron-Ziel.
    static func cronDestination(url: String?, command: String?) throws -> JSONValue {
        if let url, !url.isEmpty { return .object(["url": .string(url)]) }
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw KastellanError.invalidArgument("Cronjob braucht eine URL oder einen Befehl (Interpreter, Pfad, Parameter)")
        }
        let parts = command.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        var interpreter = "/bin/bash"
        var rest = parts
        if parts.count >= 2, parts[0].hasPrefix("/"), !parts[0].hasSuffix(".php"), !parts[0].hasSuffix(".sh") {
            interpreter = parts[0]; rest = Array(parts.dropFirst())
        } else if let first = parts.first, first.lowercased().hasSuffix(".php") {
            interpreter = "/usr/bin/php"
        }
        guard let path = rest.first else { throw KastellanError.invalidArgument("Cronjob-Befehl braucht einen Skriptpfad") }
        var o: [String: JSONValue] = ["interpreter": .string(interpreter), "path": .string(path)]
        let params = rest.dropFirst().joined(separator: " ")
        if !params.isEmpty { o["parameters"] = .string(params) }
        return .object(o)
    }
}

// MARK: - SSH

extension MittwaldAdapter {
    public func createSSHUser(username: String?, publicKeys: [String]) async throws -> SSHUser {
        guard !publicKeys.isEmpty else { throw KastellanError.invalidArgument("SSH-Nutzer braucht mindestens einen öffentlichen Schlüssel") }
        let project = try await projectID()
        let keys: [JSONValue] = publicKeys.map { key in
            let comment = key.split(separator: " ").dropFirst(2).joined(separator: " ")
            return .object(["key": .string(key), "comment": .string(comment.isEmpty ? "Kastellan" : comment)])
        }
        let created = try await client.post("/projects/\(project)/ssh-users", body: .object([
            "description": .string(username ?? "Kastellan"), "authentication": .object(["publicKeys": .array(keys)]),
        ]))
        var user = sshUser(created.string("id") != nil ? created : try await sshUserObject(named: created.string("userName") ?? ""))
        if let username, username != user.username {
            user.extra["requested_username"] = .string(username)
            user.extra["note"] = .string("Mittwald vergibt den Login-Namen selbst; der gewünschte Name ist die Beschreibung.")
        }
        return user
    }

    public func deleteSSHUser(username: String) async throws {
        let user = try await sshUserObject(named: username)
        guard let id = user.string("id") else { throw KastellanError.notFound("SSH-Nutzer \(username) bei Mittwald") }
        try await client.delete("/ssh-users/\(id)")
    }
}

// MARK: - SFTP

extension MittwaldAdapter {
    public func createFTPUser(username: String?, password: String, homePath: String, comment: String?) async throws -> FTPUser {
        let project = try await projectID()
        let created = try await client.post("/projects/\(project)/sftp-users", body: .object([
            "description": .string(username ?? comment ?? "Kastellan"),
            "authentication": .object(["password": .string(password)]),
            "directories": .array([.string(homePath.isEmpty ? "/" : homePath)]),
            "accessLevel": .string("full"),
        ]))
        guard let id = created.string("id") else { throw KastellanError.provider("Mittwald: Antwort ohne SFTP-Nutzer-ID") }
        var user = sftpUser(created["userName"] != nil ? created : try await client.get("/sftp-users/\(id)"))
        if let username, username != user.username {
            user.extra["requested_username"] = .string(username)
            user.extra["note"] = .string("Mittwald vergibt den Login-Namen selbst; der gewünschte Name ist die Beschreibung.")
        }
        return user
    }

    public func updateFTPUser(username: String, password: String?, homePath: String?, comment: String?) async throws -> FTPUser {
        let user = try await sftpUserObject(named: username)
        guard let id = user.string("id") else { throw KastellanError.notFound("SFTP-Nutzer \(username) bei Mittwald") }
        let patch = JSONValue.compactObject([
            "password": password.map { .string($0) },
            "directories": homePath.map { .array([.string($0)]) },
            "description": comment.map { .string($0) },
        ])
        if let o = patch.objectValue, !o.isEmpty {
            try await client.patch("/sftp-users/\(id)", body: patch)
        }
        return sftpUser(try await client.get("/sftp-users/\(id)"))
    }

    public func deleteFTPUser(username: String) async throws {
        let user = try await sftpUserObject(named: username)
        guard let id = user.string("id") else { throw KastellanError.notFound("SFTP-Nutzer \(username) bei Mittwald") }
        try await client.delete("/sftp-users/\(id)")
    }
}

// MARK: - MySQL

extension MittwaldAdapter {
    public func createDatabase(password: String, comment: String?, allowedHosts: [String]) async throws -> Database {
        let project = try await projectID()
        let version = try await latestMySQLVersion()
        var user: [String: JSONValue] = ["password": .string(password), "accessLevel": .string("full"), "externalAccess": .bool(!allowedHosts.isEmpty)]
        if let mask = allowedHosts.first { user["accessIpMask"] = .string(mask.contains("/") ? mask : mask + "/32") }
        let created = try await client.post("/projects/\(project)/mysql-databases", body: .object([
            "database": .object(["description": .string(comment ?? "Kastellan"), "version": .string(version)]),
            "user": .object(user),
        ]))
        guard let id = created.string("id") else { throw KastellanError.provider("Mittwald: Antwort ohne Datenbank-ID") }
        let client = self.client
        let ready = try await client.waitUntil("Datenbank \(id)") {
            try await client.get("/mysql-databases/\(id)")
        } ready: { db in
            db.string("status") == "ready" && (db["mainUser"]?.string("status") ?? "ready") == "ready"
        }
        var db = database(ready)
        if let main = ready["mainUser"]?.string("name") { db.extra["db_user"] = .string(main) }
        if allowedHosts.count > 1 {
            db.extra["note"] = .string("Mittwald kennt nur eine IP-Maske je Nutzer; nur \(allowedHosts[0]) wurde eingetragen. Das Feld hat laut Mittwald derzeit keine Wirkung.")
        }
        return db
    }

    public func updateDatabase(name: String, password: String?, comment: String?, allowedHosts: [String]?) async throws -> Database {
        let db = try await databaseObject(named: name)
        guard let id = db.string("id") else { throw KastellanError.notFound("Datenbank \(name) bei Mittwald") }
        if let comment {
            try await client.patch("/mysql-databases/\(id)", body: .object(["description": .string(comment)]))
        }
        if password != nil || allowedHosts != nil {
            guard let userID = db["mainUser"]?.string("id") else { throw KastellanError.notFound("Hauptnutzer der Datenbank \(name)") }
            var patch: [String: JSONValue] = [:]
            if let password { patch["password"] = .string(password) }
            if let allowedHosts {
                patch["externalAccess"] = .bool(!allowedHosts.isEmpty)
                if let mask = allowedHosts.first { patch["accessIpMask"] = .string(mask.contains("/") ? mask : mask + "/32") }
            }
            try await client.patch("/mysql-users/\(userID)", body: .object(patch))
        }
        return database(try await client.get("/mysql-databases/\(id)"))
    }

    public func deleteDatabase(name: String) async throws {
        let db = try await databaseObject(named: name)
        guard let id = db.string("id") else { throw KastellanError.notFound("Datenbank \(name) bei Mittwald") }
        if db["mainUser"] == nil, db.string("engine") == "redis" || db.string("port") != nil {
            try await client.delete("/redis-databases/\(id)")
        } else {
            try await client.delete("/mysql-databases/\(id)")
        }
    }
}

// MARK: - Cronjobs

extension MittwaldAdapter {
    public func createCronJob(schedule: String, url: String?, command: String?, comment: String?) async throws -> CronJob {
        let project = try await projectID()
        guard let installation = try await defaultInstallation(project: project) else {
            let list = try await client.list("/projects/\(project)/app-installations").map { "\($0.string("description") ?? $0.string("appName") ?? "?") (\($0.string("id") ?? "?"))" }
            throw KastellanError.invalidArgument(list.isEmpty
                ? "Mittwald: Cronjobs brauchen eine App-Installation im Projekt"
                : "Mittwald: mehrere App-Installationen, cron_job_create unterstützt hier nur ein Projekt mit genau einer: \(list.joined(separator: ", "))")
        }
        let created = try await client.post("/projects/\(project)/cronjobs", body: .object([
            "description": .string(comment ?? "Kastellan"),
            "interval": .string(schedule),
            "active": .bool(true),
            "timeout": .int(Self.defaultCronTimeout),
            "target": .object(["appInstallationId": .string(installation), "destination": try Self.cronDestination(url: url, command: command)]),
        ]))
        guard let id = created.string("id") else { throw KastellanError.provider("Mittwald: Antwort ohne Cronjob-ID") }
        return cronJob(try await client.get("/cronjobs/\(id)"))
    }

    public func updateCronJob(providerRef: String, schedule: String?, url: String?, command: String?, comment: String?, active: Bool?) async throws -> CronJob {
        let current = try await client.get("/cronjobs/\(providerRef)")
        var patch: [String: JSONValue] = [:]
        if let schedule { patch["interval"] = .string(schedule) }
        if let comment { patch["description"] = .string(comment) }
        if let active { patch["active"] = .bool(active) }
        if url != nil || command != nil {
            guard let installation = current["target"]?.string("appInstallationId") ?? current.string("appInstallationId") else {
                throw KastellanError.unsupported("Mittwald: Ziel eines Container-Cronjobs wird nicht über Kastellan geändert")
            }
            patch["target"] = .object(["appInstallationId": .string(installation), "destination": try Self.cronDestination(url: url, command: command)])
        }
        if !patch.isEmpty { try await client.patch("/cronjobs/\(providerRef)", body: .object(patch)) }
        return cronJob(try await client.get("/cronjobs/\(providerRef)"))
    }

    public func deleteCronJob(providerRef: String) async throws {
        try await client.delete("/cronjobs/\(providerRef)")
    }
}

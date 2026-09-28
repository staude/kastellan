import Foundation

// Webspace-Nutzer und Datenbanken bei hosting.de. Nutzer sind eigene Objekte (`webhosting/userCreate`,
// Login wird generiert), der Zugriff auf einen Webspace steht in `Webspace.accesses[]` mit
// `ftpAccess`/`sshAccess`/`homeDir` und wird über `webspaceUpdate` (komplettes Objekt) gepflegt.
// Datenbanken (`database/databaseCreate`) bekommen ihren Nutzer über `accesses[]` mit Rechten
// read/write/schema; `dbName`, `hostName` und Login-Namen werden generiert. `allowedHosts` gibt es
// nicht (`forceSsl` nur false). Beim Praxistest prüfen: Produktcodes des Pakets, Format von
// `sshKey` bei mehreren Schlüsseln, ob `userCreate` ohne Passwort geht, Nur-Lese-Felder der
// Webspace-Updates.

extension HostingDeAdapter {
    static let defaultDatabaseProduct = "database-mariadb-single-v1-12m"
    static let defaultDatabaseQuotaMB = 512
    static let webspaceReadOnly: Set<String> = ["accountId", "bundleId", "poolId", "addDate", "lastChangeDate", "status", "hostName",
                                                "storageQuotaUsed", "webspaceName", "paidUntil", "renewOn", "deletionScheduledFor",
                                                "restorableUntil", "serverIpv6", "accesses"]
    static let userReadOnly: Set<String> = ["accountId", "addDate", "lastChangeDate"]
    static let accessReadOnly: Set<String> = ["addDate", "lastChangeDate"]

    struct WebspaceAccess {
        let webspace: JSONValue
        let access: JSONValue
        var userID: String { access.string("userId") ?? "" }
    }

    func webspaces() async throws -> [JSONValue] {
        try await client.findAll("webhosting", "webspacesFind")
    }

    /// Webspace und Zugriffseintrag zu einem Login-Namen (`web…_…`), sonst `notFound`.
    func webspaceAccess(userName: String) async throws -> WebspaceAccess {
        for ws in try await webspaces() {
            if let access = ws.array("accesses").first(where: { $0.string("userName") == userName }) {
                return WebspaceAccess(webspace: ws, access: access)
            }
        }
        throw KastellanError.notFound("Webspace-Nutzer \(userName) bei hosting.de")
    }

    /// Einziger Webspace, sonst Fehler mit Liste.
    func singleWebspace() async throws -> JSONValue {
        let spaces = try await webspaces()
        if spaces.count == 1 { return spaces[0] }
        let list = spaces.map { "\($0.string("name") ?? "?") (\($0.string("id") ?? "?"))" }.joined(separator: ", ")
        throw KastellanError.invalidArgument(spaces.isEmpty
            ? "hosting.de: kein Webspace vorhanden"
            : "hosting.de: mehrere Webspaces, Nutzer bitte in der Oberfläche zuordnen: \(list)")
    }

    /// Schreibt Webspace und Zugriffsliste zurück und wartet, bis der Webspace wieder `active` ist.
    func writeWebspace(_ webspace: JSONValue, accesses: [JSONValue]) async throws -> JSONValue {
        var object = webspace.objectValue ?? [:]
        for key in Self.webspaceReadOnly { object.removeValue(forKey: key) }
        let cleanAccesses = accesses.map { a -> JSONValue in
            var o = a.objectValue ?? [:]
            for key in Self.accessReadOnly { o.removeValue(forKey: key) }
            return .object(o)
        }
        let result = try await client.call("webhosting", "webspaceUpdate", ["webspace": .object(object), "accesses": .array(cleanAccesses)])
        var current = result.response
        if result.pending || current.string("status") != "active", let id = current.string("id") ?? webspace.string("id") {
            let client = self.client
            current = try await client.waitUntilActive("Webspace") {
                try await client.findPage("webhosting", "webspacesFind", filter: .equal("WebspaceId", id), limit: 1).data.first
            }
        }
        return current
    }

    /// Nutzer anlegen; Login-Name wird von hosting.de vergeben.
    func createWebspaceUser(name: String, comment: String?, sshKey: String?, password: String) async throws -> JSONValue {
        let user = JSONValue.compactObject([
            "name": .string(name),
            "comments": comment.map { .string($0) },
            "sshKey": sshKey.map { .string($0) },
        ])
        let result = try await client.call("webhosting", "userCreate", ["user": user, "password": .string(password)])
        var current = result.response
        if result.pending || current.string("status") != "active", let id = current.string("id") {
            let client = self.client
            current = try await client.waitUntilActive("Nutzer \(name)") {
                try await client.findPage("webhosting", "usersFind", filter: .equal("UserId", id), limit: 1).data.first
            }
        }
        return current
    }

    func webspaceUser(id: String) async throws -> JSONValue {
        guard let user = try await client.findPage("webhosting", "usersFind", filter: .equal("UserId", id), limit: 1).data.first else {
            throw KastellanError.notFound("Webspace-Nutzer \(id) bei hosting.de")
        }
        return user
    }

    func updateWebspaceUser(_ user: JSONValue, password: String?, comment: String?, sshKey: String?) async throws -> JSONValue {
        var object = user.objectValue ?? [:]
        for key in Self.userReadOnly { object.removeValue(forKey: key) }
        if let comment { object["comments"] = .string(comment) }
        if let sshKey { object["sshKey"] = .string(sshKey) }
        var params: [String: JSONValue] = ["user": .object(object)]
        if let password { params["password"] = .string(password) }
        return try await client.call("webhosting", "userUpdate", params).response
    }

    /// Schaltet eine Zugriffsart (`ftpAccess` oder `sshAccess`) ab. Bleibt die andere aktiv, bleibt
    /// der Eintrag; sonst wird der Zugriff entfernt und der Nutzer gelöscht, wenn ihn kein anderer
    /// Webspace mehr nutzt.
    func disableAccess(_ found: WebspaceAccess, flag: String, other: String) async throws {
        let userID = found.userID
        var accesses = found.webspace.array("accesses")
        guard let idx = accesses.firstIndex(where: { $0.string("userId") == userID }) else { return }
        if accesses[idx].bool(other) == true {
            var entry = accesses[idx].objectValue ?? [:]
            entry[flag] = .bool(false)
            accesses[idx] = .object(entry)
            _ = try await writeWebspace(found.webspace, accesses: accesses)
            return
        }
        accesses.remove(at: idx)
        _ = try await writeWebspace(found.webspace, accesses: accesses)
        let others = try await webspaces().contains { ws in
            ws.string("id") != found.webspace.string("id") && ws.array("accesses").contains { $0.string("userId") == userID }
        }
        if !others {
            try await client.call("webhosting", "userDelete", ["userId": .string(userID)])
        }
    }

    static func splitKeys(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - FTP

extension HostingDeAdapter: FTPUserAdapter {
    func ftpUser(webspace: JSONValue, access: JSONValue) -> FTPUser {
        var extra = Self.extra(from: access, keys: ["userId", "sshAccess", "statsAccess"])
        extra["webspace_id"] = .string(webspace.string("id") ?? "")
        extra["webspace"] = .string(webspace.string("name") ?? "")
        if let host = webspace.string("hostName") { extra["host"] = .string(host) }
        let home = access.string("homeDir").map { $0.isEmpty ? "/" : $0 } ?? "/"
        return FTPUser(ref: ref("\(webspace.string("id") ?? "")/\(access.string("userId") ?? "")"), username: access.string("userName") ?? "",
                       homePath: home, status: webspace.string("status"), extra: extra)
    }

    public func listFTPUsers() async throws -> [FTPUser] {
        var users: [FTPUser] = []
        for ws in try await webspaces() {
            for access in ws.array("accesses") where access.bool("ftpAccess") == true {
                users.append(ftpUser(webspace: ws, access: access))
            }
        }
        return users.sorted { $0.username < $1.username }
    }

    public func createFTPUser(username: String?, password: String, homePath: String, comment: String?) async throws -> FTPUser {
        let webspace = try await singleWebspace()
        let user = try await createWebspaceUser(name: username ?? comment ?? "FTP-Zugang", comment: comment, sshKey: nil, password: password)
        guard let userID = user.string("id") else { throw KastellanError.provider("hosting.de: userCreate lieferte keine ID") }
        var accesses = webspace.array("accesses")
        accesses.append(.object([
            "userId": .string(userID), "ftpAccess": .bool(true), "sshAccess": .bool(false), "statsAccess": .bool(false),
            "homeDir": .string(Self.homeDir(homePath)),
        ]))
        let updated = try await writeWebspace(webspace, accesses: accesses)
        guard let access = updated.array("accesses").first(where: { $0.string("userId") == userID }) else {
            throw KastellanError.provider("hosting.de: Zugriff für Nutzer \(userID) fehlt nach webspaceUpdate")
        }
        var result = ftpUser(webspace: updated, access: access)
        if let requested = username, requested != result.username {
            result.extra["requested_username"] = .string(requested)
            result.extra["note"] = .string("hosting.de vergibt den Login-Namen selbst; der gewünschte Name steht als Anzeigename am Nutzer.")
        }
        return result
    }

    public func updateFTPUser(username: String, password: String?, homePath: String?, comment: String?) async throws -> FTPUser {
        let found = try await webspaceAccess(userName: username)
        if password != nil || comment != nil {
            let user = try await webspaceUser(id: found.userID)
            _ = try await updateWebspaceUser(user, password: password, comment: comment, sshKey: nil)
        }
        var webspace = found.webspace
        if let homePath {
            var accesses = found.webspace.array("accesses")
            if let idx = accesses.firstIndex(where: { $0.string("userId") == found.userID }) {
                var a = accesses[idx].objectValue ?? [:]
                a["homeDir"] = .string(Self.homeDir(homePath))
                accesses[idx] = .object(a)
            }
            webspace = try await writeWebspace(found.webspace, accesses: accesses)
        }
        guard let access = webspace.array("accesses").first(where: { $0.string("userId") == found.userID }) else {
            throw KastellanError.notFound("Webspace-Nutzer \(username) nach der Änderung")
        }
        return ftpUser(webspace: webspace, access: access)
    }

    public func deleteFTPUser(username: String) async throws {
        let found = try await webspaceAccess(userName: username)
        try await disableAccess(found, flag: "ftpAccess", other: "sshAccess")
    }

    /// `homeDir` ist relativ zum Webspace; führende Schrägstriche und `html/`-Präfix bleiben erhalten.
    static func homeDir(_ path: String) -> String {
        let p = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return p
    }
}

// MARK: - SSH

extension HostingDeAdapter: SSHUserAdapter {
    public func listSSHUsers() async throws -> [SSHUser] {
        let users = try await client.findAll("webhosting", "usersFind")
        var byID: [String: JSONValue] = [:]
        for u in users { if let id = u.string("id") { byID[id] = u } }
        var out: [SSHUser] = []
        for ws in try await webspaces() {
            for access in ws.array("accesses") where access.bool("sshAccess") == true {
                let userID = access.string("userId") ?? ""
                var extra = Self.extra(from: access, keys: ["userId", "ftpAccess"])
                extra["webspace_id"] = .string(ws.string("id") ?? "")
                if let host = ws.string("hostName") { extra["host"] = .string(host) }
                if let name = byID[userID]?.string("name") { extra["name"] = .string(name) }
                out.append(SSHUser(ref: ref("\(ws.string("id") ?? "")/\(userID)"), username: access.string("userName") ?? "",
                                   publicKeys: Self.splitKeys(byID[userID]?.string("sshKey")), extra: extra))
            }
        }
        return out.sorted { $0.username < $1.username }
    }

    public func createSSHUser(username: String?, publicKeys: [String]) async throws -> SSHUser {
        guard !publicKeys.isEmpty else { throw KastellanError.invalidArgument("SSH-Nutzer braucht mindestens einen öffentlichen Schlüssel") }
        let webspace = try await singleWebspace()
        // hosting.de verlangt ein Passwort; für reine Schlüssel-Logins wird eines erzeugt und verworfen.
        let user = try await createWebspaceUser(name: username ?? "SSH-Zugang", comment: nil,
                                                sshKey: publicKeys.joined(separator: "\n"), password: PasswordGenerator.generate(length: 32))
        guard let userID = user.string("id") else { throw KastellanError.provider("hosting.de: userCreate lieferte keine ID") }
        var accesses = webspace.array("accesses")
        accesses.append(.object(["userId": .string(userID), "ftpAccess": .bool(false), "sshAccess": .bool(true), "statsAccess": .bool(false)]))
        let updated = try await writeWebspace(webspace, accesses: accesses)
        guard let access = updated.array("accesses").first(where: { $0.string("userId") == userID }) else {
            throw KastellanError.provider("hosting.de: Zugriff für Nutzer \(userID) fehlt nach webspaceUpdate")
        }
        var extra: Extra = ["userId": .string(userID), "webspace_id": .string(updated.string("id") ?? "")]
        if let host = updated.string("hostName") { extra["host"] = .string(host) }
        extra["note"] = .string("Login-Name von hosting.de vergeben; Passwort erzeugt und verworfen, Anmeldung nur per Schlüssel.")
        return SSHUser(ref: ref("\(updated.string("id") ?? "")/\(userID)"), username: access.string("userName") ?? "", publicKeys: publicKeys, extra: extra)
    }

    public func deleteSSHUser(username: String) async throws {
        let found = try await webspaceAccess(userName: username)
        try await disableAccess(found, flag: "sshAccess", other: "ftpAccess")
    }
}

// MARK: - Datenbanken

extension HostingDeAdapter: DatabaseAdapter {
    func database(_ item: JSONValue) -> Database {
        var extra = Self.extra(from: item, keys: ["id", "productCode", "status", "storageQuota", "storageUsed", "dbType", "forceSsl",
                                                   "paidUntil", "renewOn", "restorableUntil", "deletionScheduledFor", "lastChangeDate"])
        extra["display_name"] = .string(item.string("name") ?? "")
        extra["accesses"] = .array(item.array("accesses").map { a in
            .object(["user": .string(a.string("userName") ?? ""), "userId": .string(a.string("userId") ?? ""), "level": .array(a.strings("accessLevel").map { .string($0) })])
        })
        return Database(ref: ref(item.string("id") ?? ""), name: item.string("dbName") ?? "", engine: (item.string("dbEngine") ?? "MariaDB").lowercased(),
                        host: item.string("hostName"), users: item.array("accesses").compactMap { $0.string("userName") },
                        comment: item.string("name"), extra: extra)
    }

    func databaseObject(name: String) async throws -> JSONValue {
        let filter = HostingDeFilter.or([.equal("DatabaseDbName", name), .equal("DatabaseName", name), .equal("DatabaseId", name)])
        guard let item = try await client.findPage("database", "databasesFind", filter: filter, limit: 1).data.first else {
            throw KastellanError.notFound("Datenbank \(name) bei hosting.de")
        }
        return item
    }

    public func listDatabases() async throws -> [Database] {
        try await client.findAll("database", "databasesFind").map { database($0) }.sorted { $0.name < $1.name }
    }

    public func createDatabase(password: String, comment: String?, allowedHosts: [String]) async throws -> Database {
        let name = comment ?? "Kastellan"
        let userResult = try await client.call("database", "userCreate", ["user": .object(["name": .string(name)]), "password": .string(password)])
        var user = userResult.response
        if userResult.pending || user.string("status") != "active", let id = user.string("id") {
            let client = self.client
            user = try await client.waitUntilActive("Datenbank-Nutzer \(name)") {
                try await client.findPage("database", "usersFind", filter: .equal("UserId", id), limit: 1).data.first
            }
        }
        guard let userID = user.string("id") else { throw KastellanError.provider("hosting.de: userCreate lieferte keine ID") }

        let dbObject = JSONValue.object([
            "name": .string(name),
            "productCode": .string(productCode([:], setting: "database_product", fallback: Self.defaultDatabaseProduct)),
            "storageQuota": .int(Self.defaultDatabaseQuotaMB),
        ])
        let access = JSONValue.object(["userId": .string(userID), "accessLevel": .array([.string("read"), .string("write"), .string("schema")])])
        let result = try await client.call("database", "databaseCreate", ["database": dbObject, "accesses": .array([access])])
        var current = result.response
        if result.pending || current.string("status") != "active", let id = current.string("id") {
            let client = self.client
            current = try await client.waitUntilActive("Datenbank \(name)") {
                try await client.findPage("database", "databasesFind", filter: .equal("DatabaseId", id), limit: 1).data.first
            }
        }
        var db = database(current)
        if let login = current.array("accesses").first?.string("userName") ?? user.string("dbUserName") { db.extra["db_user"] = .string(login) }
        if !allowedHosts.isEmpty {
            db.extra["allowed_hosts_ignored"] = .array(allowedHosts.map { .string($0) })
            db.extra["note"] = .string("hosting.de kennt keine Host-Beschränkung für Datenbank-Nutzer; allowed_hosts wurde ignoriert.")
        }
        return db
    }

    public func updateDatabase(name: String, password: String?, comment: String?, allowedHosts: [String]?) async throws -> Database {
        var current = try await databaseObject(name: name)
        if let password {
            guard let userID = current.array("accesses").first?.string("userId") else {
                throw KastellanError.notFound("Datenbank \(name) hat keinen Nutzer, dessen Passwort gesetzt werden könnte")
            }
            guard let user = try await client.findPage("database", "usersFind", filter: .equal("UserId", userID), limit: 1).data.first else {
                throw KastellanError.notFound("Datenbank-Nutzer \(userID) bei hosting.de")
            }
            var object = user.objectValue ?? [:]
            for key in Self.userReadOnly { object.removeValue(forKey: key) }
            try await client.call("database", "userUpdate", ["user": .object(object), "password": .string(password)])
        }
        if let comment {
            var object = current.objectValue ?? [:]
            object["name"] = .string(comment)
            let accesses = current.array("accesses")
            for key in ["accountId", "bundleId", "poolId", "addDate", "lastChangeDate", "status", "paidUntil", "renewOn", "deletionScheduledFor",
                        "restorableUntil", "storageQuotaIncluded", "storageQuotaUsedRatio", "storageUsed", "dbName", "hostName", "dbEngine",
                        "dbType", "restrictions", "limitations", "accesses"] {
                object.removeValue(forKey: key)
            }
            let result = try await client.call("database", "databaseUpdate", ["database": .object(object), "accesses": .array(accesses)])
            current = result.response
            if result.pending || current.string("status") != "active", let id = current.string("id") ?? object["id"]?.stringValue {
                let client = self.client
                current = try await client.waitUntilActive("Datenbank \(name)") {
                    try await client.findPage("database", "databasesFind", filter: .equal("DatabaseId", id), limit: 1).data.first
                }
            }
        }
        var db = database(current)
        if let allowedHosts, !allowedHosts.isEmpty {
            db.extra["allowed_hosts_ignored"] = .array(allowedHosts.map { .string($0) })
        }
        return db
    }

    public func deleteDatabase(name: String) async throws {
        let current = try await databaseObject(name: name)
        guard let id = current.string("id") else { throw KastellanError.notFound("Datenbank \(name) bei hosting.de") }
        try await client.call("database", "databaseDelete", ["databaseId": .string(id)])
    }
}

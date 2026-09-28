import Foundation
import Testing
@testable import KastellanCore

struct HostingDeHostingTests {
    static func item(_ fixture: String, _ index: Int = 0) throws -> JSONValue {
        let all = try JSONCoding.decoder.decode(JSONValue.self, from: HostingDeFixtures.data(fixture))
        return all["response"]!.array("data")[index]
    }

    static func objectResponse(_ value: JSONValue, pending: Bool = false) throws -> HostingDeResponse {
        let text = String(data: try JSONCoding.encoder.encode(value), encoding: .utf8)!
        return HostingDeFixtures.json(#"{"status":"\#(pending ? "pending" : "success")","errors":[],"warnings":[],"metadata":{},"response":\#(text)}"#)
    }

    static func webspace(accesses: [JSONValue]) throws -> JSONValue {
        var ws = try item("webspaces-find").objectValue!
        ws["accesses"] = .array(accesses)
        return .object(ws)
    }

    static let adminAccess: JSONValue = .object(["userId": .string("u-1"), "userName": .string("webabc123_admin"), "ftpAccess": .bool(true), "sshAccess": .bool(true), "statsAccess": .bool(false), "homeDir": .string("")])
    static let newUser: JSONValue = .object(["id": .string("u-9"), "accountId": .string("acc-42"), "name": .string("Deploy"), "userName": .string("webabc123_deploy"), "comments": .string("CI"), "sshKey": .string(""), "status": .string("active")])

    // MARK: FTP

    @Test func listFTPUsersFromWebspaceAccesses() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("webspaces-find")])
        let users = try await adapter.listFTPUsers()
        #expect(users.count == 1)
        #expect(users[0].username == "webabc123_admin")
        #expect(users[0].homePath == "/")
        #expect(users[0].ref.providerRef == "ws-1/u-1")
        #expect(users[0].extra["host"] == .string("webabc123.wh.hosting.zone"))
        #expect(users[0].extra["sshAccess"] == .bool(true))
    }

    @Test func createFTPUserCreatesUserAndAppendsAccess() async throws {
        let deployAccess: JSONValue = .object(["userId": .string("u-9"), "userName": .string("webabc123_deploy"), "ftpAccess": .bool(true), "sshAccess": .bool(false), "statsAccess": .bool(false), "homeDir": .string("html/app")])
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try HostingDeFixtures.ok("webspaces-find"),
            try Self.objectResponse(Self.newUser),
            try Self.objectResponse(Self.webspace(accesses: [Self.adminAccess, deployAccess])),
        ])
        let user = try await adapter.createFTPUser(username: "deploy", password: "pw-123", homePath: "/html/app/", comment: "CI")
        #expect(user.username == "webabc123_deploy")
        #expect(user.homePath == "html/app")
        #expect(user.extra["requested_username"] == .string("deploy"))
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["webhosting/webspacesFind", "webhosting/userCreate", "webhosting/webspaceUpdate"])
        #expect(requests[1].param("password") == .string("pw-123"))
        #expect(requests[1].param("user")?.string("name") == "deploy")
        #expect(requests[1].param("user")?.string("comments") == "CI")
        let ws = try #require(requests[2].param("webspace"))
        #expect(ws.string("id") == "ws-1")
        #expect(ws["accesses"] == nil)
        #expect(ws["hostName"] == nil)
        #expect(ws["status"] == nil)
        #expect(ws.string("productCode") == "webhosting-medium-12m")
        let accesses = requests[2].param("accesses")?.arrayValue ?? []
        #expect(accesses.count == 2)
        #expect(accesses[1].string("userId") == "u-9")
        #expect(accesses[1]["ftpAccess"] == .bool(true))
        #expect(accesses[1].string("homeDir") == "html/app")
        #expect(accesses[0]["addDate"] == nil)
    }

    @Test func createFTPUserNeedsSingleWebspace() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([HostingDeFixtures.page([], page: 1, totalPages: 0, totalEntries: 0)])
        await #expect(throws: KastellanError.invalidArgument("hosting.de: kein Webspace vorhanden")) {
            try await adapter.createFTPUser(username: nil, password: "x", homePath: "/", comment: nil)
        }
    }

    @Test func updateFTPUserPasswordAndHome() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try HostingDeFixtures.ok("webspaces-find"),
            try HostingDeFixtures.ok("users-find"),
            try Self.objectResponse(try Self.item("users-find")),
            try Self.objectResponse(Self.webspace(accesses: [.object(["userId": .string("u-1"), "userName": .string("webabc123_admin"), "ftpAccess": .bool(true), "sshAccess": .bool(true), "homeDir": .string("html")])])),
        ])
        let user = try await adapter.updateFTPUser(username: "webabc123_admin", password: "neu", homePath: "/html/", comment: "geändert")
        #expect(user.homePath == "html")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["webhosting/webspacesFind", "webhosting/usersFind", "webhosting/userUpdate", "webhosting/webspaceUpdate"])
        #expect(requests[1].param("filter") == HostingDeFilter.equal("UserId", "u-1").json)
        #expect(requests[2].param("password") == .string("neu"))
        #expect(requests[2].param("user")?.string("comments") == "geändert")
        #expect(requests[2].param("user")?.string("userName") == "webabc123_admin")
        #expect(requests[2].param("user")?["addDate"] == nil)
        let accesses = requests[3].param("accesses")?.arrayValue ?? []
        #expect(accesses[0].string("homeDir") == "html")
    }

    @Test func deleteFTPUserKeepsSSHOnlyAccess() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try HostingDeFixtures.ok("webspaces-find"),
            try Self.objectResponse(Self.webspace(accesses: [Self.adminAccess])),
        ])
        try await adapter.deleteFTPUser(username: "webabc123_admin")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["webhosting/webspacesFind", "webhosting/webspaceUpdate"])
        let accesses = requests[1].param("accesses")?.arrayValue ?? []
        #expect(accesses.count == 1)
        #expect(accesses[0]["ftpAccess"] == .bool(false))
        #expect(accesses[0]["sshAccess"] == .bool(true))
    }

    @Test func deleteFTPUserRemovesAccessAndUserWhenUnused() async throws {
        let ftpOnly: JSONValue = .object(["userId": .string("u-9"), "userName": .string("webabc123_deploy"), "ftpAccess": .bool(true), "sshAccess": .bool(false), "homeDir": .string("")])
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            HostingDeFixtures.page([String(data: try JSONCoding.encoder.encode(try Self.webspace(accesses: [Self.adminAccess, ftpOnly])), encoding: .utf8)!], page: 1, totalPages: 1),
            try Self.objectResponse(Self.webspace(accesses: [Self.adminAccess])),
            HostingDeFixtures.page([String(data: try JSONCoding.encoder.encode(try Self.webspace(accesses: [Self.adminAccess])), encoding: .utf8)!], page: 1, totalPages: 1),
            HostingDeFixtures.json(#"{"status":"success","errors":[],"warnings":[],"metadata":{},"response":null}"#),
        ])
        try await adapter.deleteFTPUser(username: "webabc123_deploy")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["webhosting/webspacesFind", "webhosting/webspaceUpdate", "webhosting/webspacesFind", "webhosting/userDelete"])
        #expect((requests[1].param("accesses")?.arrayValue ?? []).count == 1)
        #expect(requests[3].param("userId") == .string("u-9"))
    }

    @Test func unknownFTPUserIsNotFound() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("webspaces-find")])
        await #expect(throws: KastellanError.notFound("Webspace-Nutzer nix bei hosting.de")) {
            try await adapter.deleteFTPUser(username: "nix")
        }
    }

    // MARK: SSH

    @Test func listSSHUsersSplitsKeys() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("users-find"), try HostingDeFixtures.ok("webspaces-find")])
        let users = try await adapter.listSSHUsers()
        #expect(users.count == 1)
        #expect(users[0].username == "webabc123_admin")
        #expect(users[0].publicKeys == ["ssh-ed25519 AAAAC3example1 admin@example", "ssh-ed25519 AAAAC3example2 laptop@example"])
        #expect(users[0].extra["name"] == .string("Admin"))
    }

    @Test func createSSHUserSendsKeysAndGeneratedPassword() async throws {
        let sshAccess: JSONValue = .object(["userId": .string("u-9"), "userName": .string("webabc123_deploy"), "ftpAccess": .bool(false), "sshAccess": .bool(true)])
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try HostingDeFixtures.ok("webspaces-find"),
            try Self.objectResponse(Self.newUser),
            try Self.objectResponse(Self.webspace(accesses: [Self.adminAccess, sshAccess])),
        ])
        let user = try await adapter.createSSHUser(username: "deploy", publicKeys: ["ssh-ed25519 AAAA1 a", "ssh-ed25519 AAAA2 b"])
        #expect(user.username == "webabc123_deploy")
        #expect(user.publicKeys.count == 2)
        let requests = await transport.requests
        #expect(requests[1].param("user")?.string("sshKey") == "ssh-ed25519 AAAA1 a\nssh-ed25519 AAAA2 b")
        let pw = requests[1].param("password")?.stringValue ?? ""
        #expect(pw.count >= 24)
        let accesses = requests[2].param("accesses")?.arrayValue ?? []
        #expect(accesses[1]["sshAccess"] == .bool(true))
        #expect(accesses[1]["ftpAccess"] == .bool(false))
    }

    @Test func createSSHUserNeedsKeys() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([])
        await #expect(throws: KastellanError.invalidArgument("SSH-Nutzer braucht mindestens einen öffentlichen Schlüssel")) {
            try await adapter.createSSHUser(username: nil, publicKeys: [])
        }
    }

    // MARK: Datenbanken

    @Test func listDatabasesMapsGeneratedNames() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("databases-find")])
        let dbs = try await adapter.listDatabases()
        #expect(dbs.count == 1)
        #expect(dbs[0].name == "dbabc123")
        #expect(dbs[0].engine == "mariadb")
        #expect(dbs[0].host == "dbabc123.mariadb.routing.zone")
        #expect(dbs[0].users == ["dbabc123_shop"])
        #expect(dbs[0].comment == "Shop")
        #expect(dbs[0].ref.providerRef == "db-1")
    }

    @Test func createDatabaseCreatesUserThenDatabaseAndWaits() async throws {
        let user: JSONValue = .object(["id": .string("dbu-9"), "name": .string("Blog"), "dbUserName": .string("blog"), "status": .string("active")])
        var creating = try Self.item("databases-find").objectValue!
        creating["id"] = .string("db-9"); creating["status"] = .string("creating"); creating["name"] = .string("Blog")
        var active = creating; active["status"] = .string("active"); active["dbName"] = .string("dbxyz789")
        active["accesses"] = .array([.object(["userId": .string("dbu-9"), "userName": .string("dbxyz789_blog"), "accessLevel": .array([.string("read"), .string("write"), .string("schema")])])])
        let (adapter, transport, sleeps) = HostingDeFixtures.adapter([
            try Self.objectResponse(user),
            try Self.objectResponse(.object(creating), pending: true),
            HostingDeFixtures.page([String(data: try JSONCoding.encoder.encode(JSONValue.object(creating)), encoding: .utf8)!], page: 1, totalPages: 1),
            HostingDeFixtures.page([String(data: try JSONCoding.encoder.encode(JSONValue.object(active)), encoding: .utf8)!], page: 1, totalPages: 1),
        ])
        let db = try await adapter.createDatabase(password: "pw-db", comment: "Blog", allowedHosts: ["10.0.0.1"])
        #expect(db.name == "dbxyz789")
        #expect(db.users == ["dbxyz789_blog"])
        #expect(db.extra["db_user"] == .string("dbxyz789_blog"))
        #expect(db.extra["allowed_hosts_ignored"] == .array([.string("10.0.0.1")]))
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["database/userCreate", "database/databaseCreate", "database/databasesFind", "database/databasesFind"])
        #expect(requests[0].param("password") == .string("pw-db"))
        #expect(requests[0].param("user")?.string("name") == "Blog")
        #expect(requests[1].param("database")?.string("productCode") == "database-mariadb-single-v1-12m")
        #expect(requests[1].param("database")?.int("storageQuota") == 512)
        let accesses = requests[1].param("accesses")?.arrayValue ?? []
        #expect(accesses[0].string("userId") == "dbu-9")
        #expect(accesses[0].strings("accessLevel") == ["read", "write", "schema"])
        #expect(requests[2].param("filter") == HostingDeFilter.equal("DatabaseId", "db-9").json)
        #expect(await sleeps.seconds == [1])
    }

    @Test func updateDatabasePasswordUpdatesFirstUser() async throws {
        let user: JSONValue = .object(["id": .string("dbu-1"), "accountId": .string("acc-42"), "name": .string("Shop"), "dbUserName": .string("shop"), "status": .string("active"), "addDate": .string("2026-01-01T00:00:00Z")])
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try HostingDeFixtures.ok("databases-find"),
            HostingDeFixtures.page([String(data: try JSONCoding.encoder.encode(user), encoding: .utf8)!], page: 1, totalPages: 1),
            try Self.objectResponse(user),
        ])
        let db = try await adapter.updateDatabase(name: "dbabc123", password: "neu", comment: nil, allowedHosts: nil)
        #expect(db.name == "dbabc123")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["database/databasesFind", "database/usersFind", "database/userUpdate"])
        #expect(requests[0].param("filter") == HostingDeFilter.or([.equal("DatabaseDbName", "dbabc123"), .equal("DatabaseName", "dbabc123"), .equal("DatabaseId", "dbabc123")]).json)
        #expect(requests[2].param("password") == .string("neu"))
        #expect(requests[2].param("user")?["addDate"] == nil)
        #expect(requests[2].param("user")?.string("dbUserName") == "shop")
    }

    @Test func updateDatabaseCommentSendsCleanObject() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("databases-find"), try Self.objectResponse(try Self.item("databases-find"))])
        _ = try await adapter.updateDatabase(name: "dbabc123", password: nil, comment: "Shop neu", allowedHosts: nil)
        let update = await transport.requests[1]
        #expect(update.method == "database/databaseUpdate")
        let database = try #require(update.param("database"))
        #expect(database.string("name") == "Shop neu")
        #expect(database.string("id") == "db-1")
        #expect(database.string("productCode") == "database-mariadb-single-v1-12m")
        for key in ["dbName", "hostName", "status", "accesses", "storageUsed"] { #expect(database[key] == nil, "\(key)") }
        #expect((update.param("accesses")?.arrayValue ?? []).count == 1)
    }

    @Test func deleteDatabaseUsesId() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("databases-find"), HostingDeFixtures.json(#"{"status":"pending","errors":[],"warnings":[],"metadata":{},"response":null}"#)])
        try await adapter.deleteDatabase(name: "dbabc123")
        #expect(await transport.requests[1].method == "database/databaseDelete")
        #expect(await transport.requests[1].param("databaseId") == .string("db-1"))
    }

    @Test func capabilitiesDeclareHostingUsers() {
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.ftpUser, .update)))
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.sshUser, .create)))
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.database, .delete)))
        #expect(!HostingDeAdapter.capabilityMatrix.supports(Capability(.sshUser, .update)))
    }
}

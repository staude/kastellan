import Foundation
import Testing
@testable import KastellanCore

struct MittwaldUsersTests {
    static let project = "11111111-1111-4111-8111-111111111111"
    static let settings = ["project_id": project]
    static let sshUser = #"{"id":"ssh-1","userName":"ssh-abc12@p-aaaaa1","description":"deploy","active":true,"hasPassword":false,"projectId":"p","publicKeys":[{"key":"ssh-ed25519 AAAA1 laptop","comment":"laptop"}]}"#
    static let sftpUser = #"{"id":"sftp-1","userName":"sftp-abc12@p-aaaaa1","description":"upload","active":true,"hasPassword":true,"accessLevel":"full","directories":["/html/app"],"projectId":"p","publicKeys":[]}"#
    static func db(status: String = "ready", userStatus: String = "ready") -> String {
        #"{"id":"db-1","name":"mysql_abc12","description":"Shop","hostname":"mysql-abc12.project.host","externalHostname":"mysql-abc12.example.host","version":"8.4","status":"\#(status)","projectId":"p","mainUser":{"id":"u-1","name":"dbu_abc12","status":"\#(userStatus)","accessLevel":"full","mainUser":true}}"#
    }
    static let cron = #"{"id":"cj-1","description":"Aufräumen","interval":"0 3 * * *","active":true,"timeout":600,"appInstallationId":"a-1","projectId":"p","target":{"appInstallationId":"a-1","destination":{"interpreter":"/usr/bin/php","path":"/html/cron.php"}}}"#

    @Test func createSSHUserSendsKeysWithComments() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([MittwaldFixtures.json(Self.sshUser, status: 201)], settings: Self.settings)
        let user = try await adapter.createSSHUser(username: "deploy", publicKeys: ["ssh-ed25519 AAAA1 laptop"])
        #expect(user.username == "ssh-abc12@p-aaaaa1")
        #expect(user.extra["requested_username"] == .string("deploy"))
        let body = try #require(await transport.requests[0].body)
        #expect(body.string("description") == "deploy")
        #expect(body["authentication"]?.array("publicKeys") == [.object(["key": .string("ssh-ed25519 AAAA1 laptop"), "comment": .string("laptop")])])
    }

    @Test func deleteSSHUserLooksUpByUserName() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([MittwaldFixtures.page([Self.sshUser], total: 1), MittwaldFixtures.empty()], settings: Self.settings)
        try await adapter.deleteSSHUser(username: "ssh-abc12@p-aaaaa1")
        let requests = await transport.requests
        #expect(requests[1].method == "DELETE" && requests[1].path == "/ssh-users/ssh-1")
        await #expect(throws: KastellanError.self) { try await adapter.deleteSSHUser(username: "nix") }
    }

    @Test func sftpUserCreateUpdateDelete() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.json(Self.sftpUser, status: 201),
            MittwaldFixtures.page([Self.sftpUser], total: 1), MittwaldFixtures.empty(), MittwaldFixtures.json(Self.sftpUser),
            MittwaldFixtures.page([Self.sftpUser], total: 1), MittwaldFixtures.empty(),
        ], settings: Self.settings)
        let user = try await adapter.createFTPUser(username: "upload", password: "pw-123", homePath: "/html/app", comment: nil)
        #expect(user.username == "sftp-abc12@p-aaaaa1")
        #expect(user.homePath == "/html/app")
        let create = try #require(await transport.requests[0].body)
        #expect(create["authentication"] == .object(["password": .string("pw-123")]))
        #expect(create.strings("directories") == ["/html/app"])
        #expect(create.string("accessLevel") == "full")

        _ = try await adapter.updateFTPUser(username: "sftp-abc12@p-aaaaa1", password: "neu", homePath: "/html", comment: nil)
        let patch = await transport.requests[2]
        #expect(patch.method == "PATCH" && patch.path == "/sftp-users/sftp-1")
        #expect(patch.body == .object(["password": .string("neu"), "directories": .array([.string("/html")])]))

        try await adapter.deleteFTPUser(username: "sftp-abc12@p-aaaaa1")
        #expect(await transport.requests[5].method == "DELETE")
    }

    @Test func createDatabaseUsesLatestVersionAndWaitsForReady() async throws {
        let (adapter, transport, sleeps) = MittwaldFixtures.adapter([
            MittwaldFixtures.json(#"[{"number":"8.0"},{"number":"8.4"},{"number":"5.7"}]"#),
            MittwaldFixtures.json(#"{"id":"db-1","userId":"u-1"}"#, status: 201, headers: ["etag": "5"]),
            MittwaldFixtures.json(Self.db(status: "pending", userStatus: "pending")),
            MittwaldFixtures.json(Self.db()),
        ], settings: Self.settings)
        let db = try await adapter.createDatabase(password: "pw-db", comment: "Shop", allowedHosts: ["203.0.113.5", "203.0.113.6"])
        #expect(db.name == "mysql_abc12")
        #expect(db.extra["db_user"] == .string("dbu_abc12"))
        #expect(db.extra["note"] != nil)
        let requests = await transport.requests
        #expect(requests[0].path == "/mysql-versions")
        let body = try #require(requests[1].body)
        #expect(body["database"]?.string("version") == "8.4")
        #expect(body["database"]?.string("description") == "Shop")
        #expect(body["user"]?.string("password") == "pw-db")
        #expect(body["user"]?["externalAccess"] == .bool(true))
        #expect(body["user"]?.string("accessIpMask") == "203.0.113.5/32")
        #expect(requests[2].headers["if-event-reached"] == "5")
        #expect(await sleeps.seconds == [1])
    }

    @Test func updateDatabasePatchesUserAndDescription() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.page([Self.db()], total: 1), MittwaldFixtures.empty(), MittwaldFixtures.empty(), MittwaldFixtures.json(Self.db()),
        ], settings: Self.settings)
        _ = try await adapter.updateDatabase(name: "mysql_abc12", password: "neu", comment: "Shop neu", allowedHosts: [])
        let requests = await transport.requests
        #expect(requests[1].method == "PATCH" && requests[1].path == "/mysql-databases/db-1" && requests[1].body == .object(["description": .string("Shop neu")]))
        #expect(requests[2].method == "PATCH" && requests[2].path == "/mysql-users/u-1")
        #expect(requests[2].body == .object(["password": .string("neu"), "externalAccess": .bool(false)]))
    }

    @Test func deleteDatabase() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([MittwaldFixtures.page([Self.db()], total: 1), MittwaldFixtures.empty()], settings: Self.settings)
        try await adapter.deleteDatabase(name: "Shop")
        #expect(await transport.requests[1].path == "/mysql-databases/db-1")
    }

    @Test func createCronJobUsesSingleInstallation() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.page([#"{"id":"a-1","appName":"WordPress"}"#], total: 1),
            MittwaldFixtures.json(#"{"id":"cj-1"}"#, status: 201),
            MittwaldFixtures.json(Self.cron),
        ], settings: Self.settings)
        let job = try await adapter.createCronJob(schedule: "0 3 * * *", url: nil, command: "/usr/bin/php /html/cron.php --quiet", comment: "Aufräumen")
        #expect(job.ref.providerRef == "cj-1")
        let body = try #require(await transport.requests[1].body)
        #expect(body.string("interval") == "0 3 * * *")
        #expect(body["active"] == .bool(true))
        #expect(body.int("timeout") == 600)
        #expect(body["target"] == .object(["appInstallationId": .string("a-1"), "destination": .object(["interpreter": .string("/usr/bin/php"), "path": .string("/html/cron.php"), "parameters": .string("--quiet")])]))
    }

    @Test func createCronJobNeedsExactlyOneInstallation() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.page([#"{"id":"a-1","description":"Eins"}"#, #"{"id":"a-2","description":"Zwei"}"#], total: 2),
            MittwaldFixtures.page([#"{"id":"a-1","description":"Eins"}"#, #"{"id":"a-2","description":"Zwei"}"#], total: 2),
        ], settings: Self.settings)
        await #expect(throws: KastellanError.self) { try await adapter.createCronJob(schedule: "* * * * *", url: "https://example.com/x", command: nil, comment: nil) }
    }

    @Test func updateAndDeleteCronJob() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([MittwaldFixtures.json(Self.cron), MittwaldFixtures.empty(), MittwaldFixtures.json(Self.cron), MittwaldFixtures.empty()], settings: Self.settings)
        _ = try await adapter.updateCronJob(providerRef: "cj-1", schedule: "*/10 * * * *", url: "https://app.example.com/cron", command: nil, comment: nil, active: false)
        let patch = await transport.requests[1]
        #expect(patch.method == "PATCH" && patch.path == "/cronjobs/cj-1")
        #expect(patch.body == .object(["interval": .string("*/10 * * * *"), "active": .bool(false), "target": .object(["appInstallationId": .string("a-1"), "destination": .object(["url": .string("https://app.example.com/cron")])])]))
        try await adapter.deleteCronJob(providerRef: "cj-1")
        #expect(await transport.requests[3].method == "DELETE")
    }

    @Test func cronDestinationHelper() throws {
        #expect(try MittwaldAdapter.cronDestination(url: "https://x", command: nil) == .object(["url": .string("https://x")]))
        #expect(try MittwaldAdapter.cronDestination(url: nil, command: "cron.php") == .object(["interpreter": .string("/usr/bin/php"), "path": .string("cron.php")]))
        #expect(try MittwaldAdapter.cronDestination(url: nil, command: "backup.sh daily") == .object(["interpreter": .string("/bin/bash"), "path": .string("backup.sh"), "parameters": .string("daily")]))
        #expect(throws: KastellanError.self) { try MittwaldAdapter.cronDestination(url: nil, command: nil) }
        #expect(MittwaldAdapter.capabilityMatrix.supports(Capability(.database, .create)))
    }
}

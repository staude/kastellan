import Foundation
import Testing
@testable import KastellanCore

struct HostingerHostingTests {
    static let websites = HostingerFixtures.page([
        #"{"domain":"example.com","vhost_type":"main","is_enabled":true,"username":"u123456789","client_id":1,"order_id":10,"root_directory":"/public_html","website_type":"wordpress"}"#,
        #"{"domain":"app.example.com","vhost_type":"subdomain","is_enabled":true,"username":"u123456789","client_id":1,"order_id":10,"root_directory":"/public_html/app","parent_domain":"example.com","website_type":"other"}"#,
    ], page: 1, perPage: 100, total: 2)

    @Test func listSubdomainsFromWebsites() async throws {
        let (adapter, _, _) = HostingerFixtures.adapter([Self.websites])
        let subs = try await adapter.listSubdomains(parent: "example.com")
        #expect(subs.count == 1)
        #expect(subs[0].fqdn == "app.example.com" && subs[0].parent == "example.com" && subs[0].targetPath == "/public_html/app")
    }

    @Test func createAndDeleteSubdomainUseWebsiteContext() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            Self.websites, HostingerFixtures.message(),
            HostingerFixtures.json(#"[{"username":"u123456789","domain":"neu.example.com","parent_domain":"example.com","root_directory":"/public_html/neu","subdomain":"neu"}]"#),
            Self.websites, HostingerFixtures.message(),
        ])
        let sub = try await adapter.createSubdomain(fqdn: "neu.example.com", targetPath: "/public_html/neu", redirect: nil, extra: [:])
        #expect(sub.fqdn == "neu.example.com" && sub.targetPath == "/public_html/neu")
        let post = await transport.requests[1]
        #expect(post.method == "POST" && post.path == "/api/hosting/v1/accounts/u123456789/websites/example.com/subdomains")
        #expect(post.body == .object(["subdomain": .string("neu"), "directory": .string("/public_html/neu"), "is_using_public_directory": .bool(true)]))
        try await adapter.deleteSubdomain(fqdn: "neu.example.com")
        let del = await transport.requests[4]
        #expect(del.method == "DELETE" && del.path == "/api/hosting/v1/accounts/u123456789/websites/example.com/subdomains/neu")
        await #expect(throws: KastellanError.self) { try await adapter.updateSubdomain(fqdn: "neu.example.com", targetPath: "x", redirect: nil, extra: [:]) }
    }

    @Test func databasesListCreateUpdateDelete() async throws {
        let dbs = HostingerFixtures.page([#"{"name":"u123456789_shop","user":"u123456789_shop","domain":"example.com","permissions":{},"disk_usage_mb":12,"max_size_mb":3072,"host":"localhost","port":3306,"created_at":"2026-01-01T00:00:00Z"}"#], page: 1, perPage: 100, total: 1)
        let (adapter, transport, _) = HostingerFixtures.adapter([
            Self.websites, dbs,
            Self.websites, HostingerFixtures.message(), dbs, HostingerFixtures.message(),
            Self.websites, dbs, HostingerFixtures.message(),
            Self.websites, dbs, HostingerFixtures.message(),
        ])
        let list = try await adapter.listDatabases()
        #expect(list[0].name == "u123456789_shop" && list[0].users == ["u123456789_shop"] && list[0].host == "localhost")
        let created = try await adapter.createDatabase(password: "Pw-123!", comment: "Shop", allowedHosts: ["203.0.113.5"])
        #expect(created.name == "u123456789_shop")
        #expect(created.extra["allowed_hosts"] == .array([.string("203.0.113.5")]))
        let post = await transport.requests[3]
        #expect(post.path == "/api/hosting/v1/accounts/u123456789/databases")
        #expect(post.body == .object(["name": .string("shop"), "user": .string("shop"), "password": .string("Pw-123!"), "website_domain": .string("example.com")]))
        #expect(await transport.requests[5].path.hasSuffix("/databases/u123456789_shop/remote-connections"))
        _ = try await adapter.updateDatabase(name: "u123456789_shop", password: "Neu-123!", comment: nil, allowedHosts: nil)
        let patch = await transport.requests[8]
        #expect(patch.method == "PATCH" && patch.path.hasSuffix("/change-password"))
        try await adapter.deleteDatabase(name: "u123456789_shop")
        #expect(await transport.requests[11].method == "DELETE")
    }

    @Test func cronJobsCreateUpdateByRecreateDelete() async throws {
        let jobs = HostingerFixtures.json(#"[{"uid":"c1","username":"u123456789","time":"0 3 * * *","command":"php /home/u123456789/cron.php"}]"#)
        let (adapter, transport, _) = HostingerFixtures.adapter([
            Self.websites, jobs,
            Self.websites, HostingerFixtures.json(#"{"uid":"c2","username":"u123456789","time":"*/5 * * * *","command":"curl -s 'https://app.example.com/cron' > /dev/null"}"#),
            jobs, HostingerFixtures.message(), HostingerFixtures.json(#"{"uid":"c3","username":"u123456789","time":"0 4 * * *","command":"php /home/u123456789/cron.php"}"#),
            HostingerFixtures.message(),
        ])
        let list = try await adapter.listCronJobs()
        #expect(list[0].ref.providerRef == "u123456789/c1" && list[0].schedule == "0 3 * * *")
        let created = try await adapter.createCronJob(schedule: "*/5 * * * *", url: "https://app.example.com/cron", command: nil, comment: nil)
        #expect(created.url == "https://app.example.com/cron")
        #expect(await transport.requests[3].body?.string("command") == "curl -s 'https://app.example.com/cron' > /dev/null")
        let updated = try await adapter.updateCronJob(providerRef: "u123456789/c1", schedule: "0 4 * * *", url: nil, command: nil, comment: nil, active: nil)
        #expect(updated.ref.providerRef == "u123456789/c3" && updated.extra["note"] != nil)
        let requests = await transport.requests
        #expect(requests[5].method == "DELETE" && requests[5].path.hasSuffix("/cron-jobs/c1"))
        #expect(requests[6].method == "POST" && requests[6].body == .object(["time": .string("0 4 * * *"), "command": .string("php /home/u123456789/cron.php")]))
        try await adapter.deleteCronJob(providerRef: "u123456789/c3")
        #expect(await transport.requests[7].method == "DELETE")
        await #expect(throws: KastellanError.self) { try await adapter.updateCronJob(providerRef: "u123456789/c3", schedule: nil, url: nil, command: nil, comment: nil, active: false) }
        #expect(HostingerAdapter.capabilityMatrix.supports(Capability(.cronJob, .create)))
    }

    @Test func websiteResolutionNeedsSingleMain() async throws {
        let two = HostingerFixtures.page([
            #"{"domain":"example.com","vhost_type":"main","username":"u1","root_directory":"/public_html"}"#,
            #"{"domain":"example.net","vhost_type":"main","username":"u2","root_directory":"/public_html"}"#,
        ], page: 1, perPage: 100, total: 2)
        let (adapter, _, _) = HostingerFixtures.adapter([two, two])
        await #expect(throws: KastellanError.self) { try await adapter.createDatabase(password: "x", comment: nil, allowedHosts: []) }
        let (fixed, transport, _) = HostingerFixtures.adapter([two, HostingerFixtures.message(), HostingerFixtures.json("[]")], settings: ["website": "example.net"])
        await #expect(throws: KastellanError.self) { try await fixed.createDatabase(password: "x", comment: "db", allowedHosts: []) }
        #expect(await transport.requests[1].path == "/api/hosting/v1/accounts/u2/databases")
    }
}

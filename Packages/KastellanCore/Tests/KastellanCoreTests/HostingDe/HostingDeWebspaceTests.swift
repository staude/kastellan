import Foundation
import Testing
@testable import KastellanCore

struct HostingDeWebspaceTests {
    static func item(_ fixture: String, _ index: Int = 0) throws -> JSONValue {
        let all = try JSONCoding.decoder.decode(JSONValue.self, from: HostingDeFixtures.data(fixture))
        return all["response"]!.array("data")[index]
    }

    static func page(_ values: [JSONValue]) throws -> HostingDeResponse {
        HostingDeFixtures.page(try values.map { String(data: try JSONCoding.encoder.encode($0), encoding: .utf8)! }, page: 1, totalPages: 1)
    }

    static func objectResponse(_ value: JSONValue, pending: Bool = false) throws -> HostingDeResponse {
        let text = String(data: try JSONCoding.encoder.encode(value), encoding: .utf8)!
        return HostingDeFixtures.json(#"{"status":"\#(pending ? "pending" : "success")","errors":[],"warnings":[],"metadata":{},"response":\#(text)}"#)
    }

    static let dailyJob: JSONValue = .object(["type": .string("php"), "script": .string("html/cron.php"), "schedule": .string("daily"), "daypart": .string("1-5"), "comments": .string("Aufräumen")])
    static let urlJob: JSONValue = .object(["type": .string("url"), "url": .string("https://app.example.com/cron"), "schedule": .string("5min")])

    static func webspace(cronJobs: [JSONValue]) throws -> JSONValue {
        var ws = try item("webspaces-find").objectValue!
        ws["cronJobs"] = .array(cronJobs)
        return .object(ws)
    }

    // MARK: Cronjobs

    @Test func scheduleMappingTable() throws {
        let cases: [(String, [String: JSONValue])] = [
            ("*/5 * * * *", ["schedule": .string("5min")]),
            ("* * * * *", ["schedule": .string("1min")]),
            ("0 * * * *", ["schedule": .string("1hour")]),
            ("0 */6 * * *", ["schedule": .string("6hour")]),
            ("30 3 * * *", ["schedule": .string("daily"), "daypart": .string("1-5")]),
            ("0 14 * * *", ["schedule": .string("daily"), "daypart": .string("13-17")]),
            ("0 23 * * *", ["schedule": .string("daily"), "daypart": .string("21-1")]),
            ("0 6 * * 1", ["schedule": .string("weekly"), "daypart": .string("5-9"), "weekday": .string("mon")]),
            ("0 6 * * sun", ["schedule": .string("weekly"), "daypart": .string("5-9"), "weekday": .string("sun")]),
            ("0 2 15 * *", ["schedule": .string("monthly"), "daypart": .string("1-5"), "dayOfMonth": .int(15)]),
            ("daily 9-13", ["schedule": .string("daily"), "daypart": .string("9-13")]),
            ("weekly", ["schedule": .string("weekly"), "daypart": .string("1-5"), "weekday": .string("mon")]),
            ("10min", ["schedule": .string("10min")]),
        ]
        for (input, expected) in cases {
            #expect(try HostingDeAdapter.scheduleFields(input) == expected, "\(input)")
        }
        #expect(throws: KastellanError.self) { try HostingDeAdapter.scheduleFields("*/7 * * * *") }
        #expect(throws: KastellanError.self) { try HostingDeAdapter.scheduleFields("0 3 1 1 *") }
        #expect(throws: KastellanError.self) { try HostingDeAdapter.scheduleFields("alle zwei Wochen") }
    }

    @Test func listCronJobsFromWebspace() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try Self.page([try Self.webspace(cronJobs: [Self.dailyJob, Self.urlJob])])])
        let jobs = try await adapter.listCronJobs()
        #expect(jobs.count == 2)
        #expect(jobs[0].ref.providerRef == "ws-1/0")
        #expect(jobs[0].schedule == "daily 1-5h")
        #expect(jobs[0].command == "html/cron.php")
        #expect(jobs[0].comment == "Aufräumen")
        #expect(jobs[1].url == "https://app.example.com/cron")
        #expect(jobs[1].schedule == "5min")
        #expect(jobs[1].command == nil)
    }

    @Test func createCronJobAppendsToListAndKeepsAccesses() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try Self.page([try Self.webspace(cronJobs: [Self.dailyJob])]),
            try Self.objectResponse(try Self.webspace(cronJobs: [Self.dailyJob, Self.urlJob])),
        ])
        let job = try await adapter.createCronJob(schedule: "*/5 * * * *", url: "https://app.example.com/cron", command: nil, comment: nil)
        #expect(job.ref.providerRef == "ws-1/1")
        #expect(job.url == "https://app.example.com/cron")
        let update = await transport.requests[1]
        #expect(update.method == "webhosting/webspaceUpdate")
        let jobs = update.param("webspace")?.array("cronJobs") ?? []
        #expect(jobs.count == 2)
        #expect(jobs[1] == .object(["type": .string("url"), "url": .string("https://app.example.com/cron"), "schedule": .string("5min")]))
        #expect((update.param("accesses")?.arrayValue ?? []).count == 1)
        #expect(update.param("webspace")?["hostName"] == nil)
    }

    @Test func createCronJobValidatesScriptPath() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try HostingDeFixtures.ok("webspaces-find")])
        await #expect(throws: KastellanError.self) {
            try await adapter.createCronJob(schedule: "daily", url: nil, command: "/usr/bin/backup.sh", comment: nil)
        }
    }

    @Test func updateCronJobReplacesScheduleFieldsAndKeepsRest() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try Self.page([try Self.webspace(cronJobs: [Self.dailyJob])]),
            try Self.objectResponse(try Self.webspace(cronJobs: [Self.dailyJob])),
        ])
        _ = try await adapter.updateCronJob(providerRef: "ws-1/0", schedule: "0 */2 * * *", url: nil, command: nil, comment: "alle zwei Stunden", active: nil)
        let requests = await transport.requests
        #expect(requests[0].param("filter") == HostingDeFilter.equal("WebspaceId", "ws-1").json)
        let job = try #require(requests[1].param("webspace")?.array("cronJobs").first)
        #expect(job.string("schedule") == "2hour")
        #expect(job["daypart"] == nil)
        #expect(job.string("script") == "html/cron.php")
        #expect(job.string("type") == "php")
        #expect(job.string("comments") == "alle zwei Stunden")
    }

    @Test func cronJobCannotBePaused() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([])
        await #expect(throws: KastellanError.unsupported("hosting.de-Cronjobs lassen sich nicht pausieren, nur löschen")) {
            try await adapter.updateCronJob(providerRef: "ws-1/0", schedule: nil, url: nil, command: nil, comment: nil, active: false)
        }
    }

    @Test func deleteCronJobRemovesEntry() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try Self.page([try Self.webspace(cronJobs: [Self.dailyJob, Self.urlJob])]),
            try Self.objectResponse(try Self.webspace(cronJobs: [Self.urlJob])),
        ])
        try await adapter.deleteCronJob(providerRef: "ws-1/0")
        let jobs = await transport.requests[1].param("webspace")?.array("cronJobs") ?? []
        #expect(jobs == [Self.urlJob])
        await #expect(throws: KastellanError.self) { try await adapter.deleteCronJob(providerRef: "kaputt") }
    }

    // MARK: Verzeichnisschutz

    static let protectedVHost: JSONValue = .object([
        "id": .string("vh-2"), "domainName": .string("app.example.com"), "webspaceId": .string("ws-1"), "webRoot": .string("app"), "status": .string("active"),
        "httpUsers": .array([.string("admin"), .string("gast")]),
        "locations": .array([
            .object(["locationType": .string("generic"), "matchType": .string("default"), "matchString": .string(""), "phpEnabled": .bool(true)]),
            .object(["locationType": .string("location"), "matchType": .string("directory"), "matchString": .string("/admin"), "phpEnabled": .bool(true), "restrictToHttpUsers": .array([.string("admin"), .string("gast")])]),
        ]),
        "addDate": .string("2026-02-01T00:00:00Z"), "systemAlias": .string("vh-2.wh.hosting.zone"),
    ])

    @Test func splitProtectionPath() throws {
        let a = try HostingDeAdapter.splitProtectionPath("app.example.com/admin/")
        #expect(a.domain == "app.example.com" && a.match == "/admin")
        let b = try HostingDeAdapter.splitProtectionPath("Example.com")
        #expect(b.domain == "example.com" && b.match == "/")
        #expect(throws: KastellanError.self) { try HostingDeAdapter.splitProtectionPath("/admin") }
    }

    @Test func listProtectionsFromVHostLocations() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try Self.page([Self.protectedVHost, try Self.item("vhosts-find", 0)])])
        let list = try await adapter.listDirectoryProtections()
        #expect(list.count == 1)
        #expect(list[0].path == "app.example.com/admin")
        #expect(list[0].users == ["admin", "gast"])
        #expect(list[0].extra["vhost_id"] == .string("vh-2"))
    }

    @Test func createProtectionAddsUserPasswordAndLocation() async throws {
        var after = Self.protectedVHost.objectValue!
        after["httpUsers"] = .array([.string("admin"), .string("gast"), .string("chef")])
        after["locations"] = .array(Self.protectedVHost.array("locations") + [.object(["locationType": .string("location"), "matchType": .string("directory"), "matchString": .string("/intern"), "restrictToHttpUsers": .array([.string("chef")])])])
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.page([Self.protectedVHost]), try Self.objectResponse(.object(after))])
        let result = try await adapter.createDirectoryProtection(path: "app.example.com/intern", username: "chef", password: "pw-chef", realm: nil)
        #expect(result.path == "app.example.com/intern")
        #expect(result.users == ["chef"])
        let vhost = try #require(await transport.requests[1].param("vhost"))
        #expect(vhost.strings("httpUsers") == ["admin", "gast", "chef"])
        #expect(vhost.array("setHttpUserPasswords") == [.object(["name": .string("chef"), "password": .string("pw-chef")])])
        let locations = vhost.array("locations")
        #expect(locations.count == 3)
        #expect(locations[2].string("matchString") == "/intern")
        #expect(locations[2].string("locationType") == "location")
        #expect(locations[2].strings("restrictToHttpUsers") == ["chef"])
        #expect(vhost["addDate"] == nil)
        #expect(vhost["systemAlias"] == nil)
    }

    @Test func createProtectionOnExistingLocationAddsUser() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.page([Self.protectedVHost]), try Self.objectResponse(Self.protectedVHost)])
        _ = try await adapter.createDirectoryProtection(path: "app.example.com/admin", username: "admin", password: "neu", realm: "Intern")
        let vhost = try #require(await transport.requests[1].param("vhost"))
        #expect(vhost.strings("httpUsers") == ["admin", "gast"])
        #expect(vhost.array("locations").count == 2)
        #expect(vhost.array("locations")[1].strings("restrictToHttpUsers") == ["admin", "gast"])
    }

    @Test func deleteProtectionRemovesUserAndPrunesHttpUsers() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try Self.page([Self.protectedVHost]), try Self.objectResponse(Self.protectedVHost),
            try Self.page([Self.protectedVHost]), try Self.objectResponse(Self.protectedVHost),
        ])
        try await adapter.deleteDirectoryProtection(path: "app.example.com/admin", username: "gast")
        let first = try #require(await transport.requests[1].param("vhost"))
        #expect(first.array("locations")[1].strings("restrictToHttpUsers") == ["admin"])
        #expect(first.strings("httpUsers") == ["admin"])

        try await adapter.deleteDirectoryProtection(path: "app.example.com/admin", username: nil)
        let second = try #require(await transport.requests[3].param("vhost"))
        #expect(second.array("locations")[1].strings("restrictToHttpUsers") == [])
        #expect(second.strings("httpUsers") == [])
    }

    @Test func deleteUnknownProtectionIsNotFound() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try Self.page([Self.protectedVHost])])
        await #expect(throws: KastellanError.notFound("Verzeichnisschutz app.example.com/nix bei hosting.de")) {
            try await adapter.deleteDirectoryProtection(path: "app.example.com/nix", username: nil)
        }
    }

    // MARK: Zertifikate

    static let sslVHost: JSONValue = .object([
        "id": .string("vh-1"), "domainName": .string("example.com"), "webspaceId": .string("ws-1"), "webRoot": .string("example.com"), "status": .string("active"),
        "sslSettings": .object(["profile": .string("modern"), "managedSslProductCode": .string("ssl-letsencrypt-dv-3m"), "managedSslStatus": .string("active"), "hstsMaxAge": .int(0)]),
        "locations": .array([]),
    ])

    @Test func listCertificatesFromVHostsAndSSLService() async throws {
        let order: JSONValue = .object(["id": .string("cert-1"), "status": .string("active"), "orderStatus": .string("complete"), "commonName": .string("shop.example.com"), "brand": .string("DigiCert"), "endDate": .string("2027-01-20T04:33:40Z"), "productCode": .string("GeoTrust RapidSSL")])
        let (adapter, _, _) = HostingDeFixtures.adapter([
            try Self.page([Self.sslVHost, try Self.item("vhosts-find", 1)]),
            try Self.page([order]),
        ])
        let certs = try await adapter.listCertificates()
        #expect(certs.count == 2)
        #expect(certs[0].hostname == "example.com")
        #expect(certs[0].issuer == "Let's Encrypt")
        #expect(certs[0].autoRenew == true)
        #expect(certs[0].forceHTTPS == nil)
        #expect(certs[1].hostname == "shop.example.com")
        #expect(certs[1].issuer == "DigiCert")
        #expect(certs[1].validUntil == HostingDeDates.date("2027-01-20T04:33:40Z"))
        #expect(certs[1].ref.providerRef == "ssl/cert-1")
    }

    @Test func listCertificatesIgnoresSSLServiceErrors() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try Self.page([Self.sslVHost]), try HostingDeFixtures.ok("error-auth")])
        let certs = try await adapter.listCertificates()
        #expect(certs.count == 1)
    }

    @Test func updateCertificateActivatesLetsEncrypt() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([
            try Self.page([try Self.item("vhosts-find", 1)]),
            try Self.objectResponse(Self.sslVHost),
        ])
        let cert = try await adapter.updateCertificate(hostname: "app.example.com", forceHTTPS: nil, extra: [:])
        #expect(cert.issuer == "Let's Encrypt")
        let req = await transport.requests[1]
        #expect(req.method == "webhosting/vhostActivateSsl")
        let ssl = try #require(req.param("vhost")?["sslSettings"])
        #expect(ssl.string("managedSslProductCode") == "ssl-letsencrypt-dv-3m")
        #expect(ssl.string("profile") == "modern")
        #expect(req.param("vhost")?["status"] == nil)
    }

    @Test func updateCertificateForceHTTPSSetsHSTS() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.page([Self.sslVHost]), try Self.objectResponse(Self.sslVHost)])
        let cert = try await adapter.updateCertificate(hostname: "example.com", forceHTTPS: true, extra: [:])
        let req = await transport.requests[1]
        #expect(req.method == "webhosting/vhostUpdate")
        #expect(req.param("vhost")?["sslSettings"]?.int("hstsMaxAge") == 31_536_000)
        #expect(cert.extra["note"] != nil)
    }

    @Test func capabilitiesDeclareWebspaceExtras() {
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.cronJob, .update)))
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.directoryProtection, .create)))
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.certificate, .update)))
        #expect(!HostingDeAdapter.capabilityMatrix.supports(Capability(.dkim, .get)))
        #expect(!HostingDeAdapter.capabilityMatrix.supports(Capability(.firewall, .list)))
    }
}

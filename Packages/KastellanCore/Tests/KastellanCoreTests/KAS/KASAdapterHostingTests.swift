import Foundation
import Testing
@testable import KastellanCore

struct KASAdapterHostingTests {
    @Test func capabilityMatrixIsComplete() {
        let m = KASAdapter.capabilityMatrix
        #expect(m.resources == [
            .domain, .subdomain, .dnsZone, .dnsRecord, .dkim, .mailbox, .mailForward, .mailAutoresponder, .mailingList,
            .ftpUser, .database, .cronJob, .certificate, .directoryProtection, .subaccount,
        ])
        #expect(m.supports(Capability(.ftpUser, .update)))
        #expect(!m.supports(Capability(.ftpUser, .setPassword)))
        #expect(m.supports(Capability(.database, .delete)))
        #expect(m.supports(Capability(.cronJob, .create)))
        #expect(m.supports(Capability(.certificate, .list)))
        #expect(m.supports(Capability(.certificate, .update)))
        #expect(!m.supports(Capability(.certificate, .create)))
        #expect(m.supports(Capability(.directoryProtection, .create)))
        #expect(!m.supports(Capability(.directoryProtection, .update)))
        #expect(m.supports(Capability(.subaccount, .create)))
        #expect(!m.supports(Capability(.subaccount, .update)))
        #expect(!m.supports(Capability(.sshUser, .list)))
        #expect(!m.supports(Capability(.databaseUser, .list)))
        // Jede Fähigkeit des Aktionskatalogs, die KAS deklariert, hat ein Protokoll dahinter.
        let adapter: any ProviderAdapter = KASAdapter(connection: Connection(profileID: "c", provider: "allinkl", label: ""), secrets: InMemorySecretProvider())
        #expect(adapter as? any FTPUserAdapter != nil)
        #expect(adapter as? any DatabaseAdapter != nil)
        #expect(adapter as? any CronJobAdapter != nil)
        #expect(adapter as? any CertificateAdapter != nil)
        #expect(adapter as? any DirectoryProtectionAdapter != nil)
        #expect(adapter as? any SubaccountAdapter != nil)
    }

    // MARK: - FTP

    @Test func listFTPUsersMapsFixture() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_ftpusers")])
        let users = try await adapter.listFTPUsers()
        #expect(users.map(\.username) == ["w00abcde", "f0abcd12"])
        let second = try #require(users.last)
        #expect(second.ref.providerRef == "f0abcd12")
        #expect(second.homePath == "/")
        #expect(second.extra["comment"] == .string("Max FTP"))
        #expect(second.extra["ftp_is_main_user"] == .string("N"))
        #expect(second.extra["ftp_permission_write"] == .string("Y"))
        #expect(second.extra["ftp_password"] == nil)
        #expect(second.extra["ftp_passwort"] == nil)
        #expect(second.extra["ftp_comment"] == nil)
    }

    @Test func createFTPUserSendsPasswordAndRereads() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_ftpuser", returnInfo: "f0abcd12"),
            try KASFixtures.response("get_ftpusers"),
        ])
        let user = try await adapter.createFTPUser(username: nil, password: "Ftp-geheim-1", homePath: "/", comment: "Max FTP")
        #expect(user.username == "f0abcd12")
        #expect(user.extra["comment"] == .string("Max FTP"))
        let add = try #require(await transport.requests.first { $0.action == "add_ftpuser" })
        #expect(add.requestParams == ["ftp_password": "Ftp-geheim-1", "ftp_path": "/", "ftp_comment": "Max FTP"])
        let json = String(decoding: try JSONEncoder().encode(user), as: UTF8.self)
        #expect(!json.contains("Ftp-geheim-1"))
    }

    @Test func createFTPUserWithWishedNameIsUnsupported() async throws {
        let (adapter, _) = try KASFixtures.adapter([])
        await #expect(throws: KastellanError.self) {
            try await adapter.createFTPUser(username: "wunsch", password: "x", homePath: "/", comment: nil)
        }
    }

    @Test func updateAndDeleteFTPUser() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("update_ftpuser", returnInfo: "TRUE"),
            try KASFixtures.response("get_ftpusers"),
            KASFixtures.scalarResponse("delete_ftpuser", returnInfo: "TRUE"),
        ])
        let user = try await adapter.updateFTPUser(username: "f0abcd12", password: "Neu", homePath: "/web/", comment: nil)
        #expect(user.username == "f0abcd12")
        try await adapter.deleteFTPUser(username: "f0abcd12")
        let requests = await transport.requests
        #expect(requests[1].requestParams == ["ftp_login": "f0abcd12", "ftp_password": "Neu", "ftp_path": "/web/"])
        #expect(requests.last?.action == "delete_ftpuser")
        #expect(requests.last?.requestParams == ["ftp_login": "f0abcd12"])
    }

    // MARK: - Datenbank

    @Test func listDatabasesMapsFixture() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_databases")])
        let dbs = try await adapter.listDatabases()
        #expect(dbs.map(\.name) == ["d0abcd02", "d0abcd01"])
        let first = try #require(dbs.first)
        #expect(first.ref.providerRef == "d0abcd02")
        #expect(first.engine == "mysql")
        #expect(first.users == ["d0abcd02"])
        #expect(first.comment == "cloud.beispiel-aktion.org: Nextcloud 2024-04-07")
        #expect(first.extra["allowed_hosts"] == .array([.string("localhost")]))
        #expect(first.extra["used_mb"] == .int(20810))
        #expect(first.extra["database_password"] == nil)
    }

    @Test func createDatabaseSendsParams() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_database", returnInfo: "d0abcd01"),
            try KASFixtures.response("get_databases"),
        ])
        let db = try await adapter.createDatabase(password: "Db-geheim-1", comment: "example-cloud.de: Nextcloud 2022-09-22", allowedHosts: ["localhost", "10.0.0.1"])
        #expect(db.name == "d0abcd01")
        let add = try #require(await transport.requests.first { $0.action == "add_database" })
        #expect(add.requestParams == [
            "database_password": "Db-geheim-1", "database_comment": "example-cloud.de: Nextcloud 2022-09-22", "database_allowed_hosts": "localhost,10.0.0.1",
        ])
    }

    @Test func updateAndDeleteDatabase() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("update_database", returnInfo: "TRUE"),
            try KASFixtures.response("get_databases"),
            KASFixtures.scalarResponse("delete_database", returnInfo: "TRUE"),
        ])
        _ = try await adapter.updateDatabase(name: "d0abcd02", password: nil, comment: "neu", allowedHosts: ["localhost"])
        try await adapter.deleteDatabase(name: "d0abcd02")
        let requests = await transport.requests
        #expect(requests[1].requestParams == ["database_login": "d0abcd02", "database_comment": "neu", "database_allowed_hosts": "localhost"])
        #expect(requests.last?.requestParams == ["database_login": "d0abcd02"])
    }

    // MARK: - Cronjob

    @Test func listCronJobsMapsFixture() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_cronjobs")])
        let jobs = try await adapter.listCronJobs()
        #expect(jobs.map(\.ref.providerRef) == ["320775", "324135"])
        let first = try #require(jobs.first)
        #expect(first.schedule == "50 7 * * *")
        #expect(first.url == "https://planer.beispiel-app.de/cron/fetch-actors?token=***")
        #expect(first.command == nil)
        #expect(first.comment == "daten holen")
        #expect(first.active)
        #expect(first.extra["mail_subject"] == .string("comment"))
        #expect(first.extra["shell_command"] == .null)
        #expect(first.extra["http_password"] == nil)
        #expect(first.extra["http_url"] == nil)
    }

    @Test func createCronJobSplitsScheduleAndURL() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_cronjob", returnInfo: "324135"),
            try KASFixtures.response("get_cronjobs"),
        ])
        let job = try await adapter.createCronJob(schedule: "17 7 * * *", url: "https://planer.beispiel-app.de/cron/fetch-durations?token=***", command: nil, comment: "Filmlaufzeiten aktualisieren")
        #expect(job.ref.providerRef == "324135")
        let add = try #require(await transport.requests.first { $0.action == "add_cronjob" })
        #expect(add.requestParams == [
            "protocol": "https", "http_url": "planer.beispiel-app.de/cron/fetch-durations?token=***",
            "minute": "17", "hour": "7", "day_of_month": "*", "month": "*", "day_of_week": "*", "cronjob_comment": "Filmlaufzeiten aktualisieren",
        ])
    }

    @Test func cronJobValidation() async throws {
        let (adapter, _) = try KASFixtures.adapter([])
        await #expect(throws: KastellanError.self) { try await adapter.createCronJob(schedule: "* * *", url: "https://x.de/", command: nil, comment: nil) }
        await #expect(throws: KastellanError.self) { try await adapter.createCronJob(schedule: "* * * * *", url: "x.de/pfad", command: nil, comment: nil) }
        await #expect(throws: KastellanError.self) { try await adapter.createCronJob(schedule: "* * * * *", url: "ftp://x.de/", command: nil, comment: nil) }
        let error = await #expect(throws: KastellanError.self) {
            try await adapter.createCronJob(schedule: "* * * * *", url: nil, command: "php cron.php", comment: nil)
        }
        guard case .unsupported? = error else {
            Issue.record("Erwartet unsupported, bekommen \(String(describing: error))")
            return
        }
    }

    @Test func updateCronJobMergesWithCurrentState() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            try KASFixtures.response("get_cronjobs"),
            KASFixtures.scalarResponse("update_cronjob", returnInfo: "TRUE"),
            try KASFixtures.response("get_cronjobs"),
        ])
        let job = try await adapter.updateCronJob(providerRef: "320775", schedule: "0 6 * * 1", url: nil, command: nil, comment: nil, active: false)
        #expect(job.ref.providerRef == "320775")
        let update = try #require(await transport.requests.first { $0.action == "update_cronjob" })
        #expect(update.requestParams == [
            "cronjob_id": "320775", "protocol": "https", "http_url": "planer.beispiel-app.de/cron/fetch-actors?token=***",
            "minute": "0", "hour": "6", "day_of_month": "*", "month": "*", "day_of_week": "1",
            "cronjob_comment": "daten holen", "is_active": "N",
        ])
    }

    @Test func updateUnknownCronJobIsNotFoundAndDeleteSendsID() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            try KASFixtures.response("get_cronjobs"),
            KASFixtures.scalarResponse("delete_cronjob", returnInfo: "TRUE"),
        ])
        await #expect(throws: KastellanError.notFound("Cronjob 1")) {
            try await adapter.updateCronJob(providerRef: "1", schedule: nil, url: nil, command: nil, comment: nil, active: nil)
        }
        try await adapter.deleteCronJob(providerRef: "320775")
        #expect(await transport.requests.last?.requestParams == ["cronjob_id": "320775"])
    }

    // MARK: - Zertifikat

    @Test func listCertificatesDerivesFromDomainsAndSubdomains() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_domains"), try KASFixtures.response("get_subdomains")])
        let certs = try await adapter.listCertificates()
        // Domains im Fixture haben kein SNI-Zertifikat, beide Subdomains schon.
        #expect(certs.map(\.hostname) == ["planer.beispiel-app.de", "cloud.beispiel-aktion.org"])
        let first = try #require(certs.first)
        #expect(first.ref.providerRef == "planer.beispiel-app.de")
        #expect(first.forceHTTPS == nil)
        #expect(first.issuer == nil)
        #expect(first.extra["kind"] == .string("sni"))
        #expect(first.extra["active"] == .bool(true))
        #expect(first.extra["ssl_certificate_sni_type"] == .string("unknown"))
        #expect(first.extra["ssl_certificate_sni_key"] == nil)
    }

    @Test func certificateWithForceHTTPSAndHSTS() async throws {
        let (adapter, _) = try KASFixtures.adapter([
            KASFixtures.mapArrayResponse("get_domains", items: [[
                "domain_name": "example.com", "ssl_certificate_sni": "Y", "ssl_certificate_sni_is_active": "j",
                "ssl_certificate_sni_force_https": "Y", "ssl_certificate_sni_hsts_max_age": "31536000",
            ]]),
            KASFixtures.mapArrayResponse("get_subdomains", items: []),
        ])
        let cert = try #require(try await adapter.listCertificates().first)
        #expect(cert.hostname == "example.com")
        #expect(cert.forceHTTPS == true)
        #expect(cert.extra["hsts_max_age"] == .int(31536000))
    }

    @Test func updateCertificateSendsForceHTTPSAndUpload() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("update_ssl", returnInfo: "TRUE"),
            KASFixtures.mapArrayResponse("get_domains", items: [["domain_name": "example.com", "ssl_certificate_sni": "Y", "ssl_certificate_sni_force_https": "Y"]]),
            KASFixtures.mapArrayResponse("get_subdomains", items: []),
        ])
        let cert = try await adapter.updateCertificate(hostname: "example.com", forceHTTPS: true, extra: [
            "ssl_certificate_sni_crt": .string("CERT"), "ssl_certificate_sni_key": .string("KEY"), "ssl_certificate_sni_bundle": .string("BUNDLE"),
        ])
        #expect(cert.forceHTTPS == true)
        #expect(cert.extra["ssl_certificate_sni_key"] == nil)
        let update = try #require(await transport.requests.first { $0.action == "update_ssl" })
        #expect(update.requestParams == [
            "hostname": "example.com", "ssl_certificate_force_https": "Y",
            "ssl_certificate_sni_crt": "CERT", "ssl_certificate_sni_key": "KEY", "ssl_certificate_sni_bundle": "BUNDLE",
        ])
    }

    // MARK: - Verzeichnisschutz (ohne Fixture)

    @Test func directoryProtectionGroupsUsersByPath() async throws {
        let (adapter, _) = try KASFixtures.adapter([
            KASFixtures.mapArrayResponse("get_directoryprotection", items: [
                ["directory_path": "/example.com/intern/", "directory_user": "Max", "directory_authname": "Intern"],
                ["directory_path": "/example.com/intern/", "directory_user": "gast", "directory_authname": "Intern"],
                ["directory_path": "/example.com/admin/", "directory_user": "admin", "directory_authname": nil, "directory_password": "x"],
            ]),
        ])
        let protections = try await adapter.listDirectoryProtections()
        #expect(protections.map(\.path) == ["/example.com/intern/", "/example.com/admin/"])
        #expect(protections.first?.users == ["Max", "gast"])
        #expect(protections.first?.realm == "Intern")
        #expect(protections.last?.realm == nil)
        #expect(protections.last?.extra["directory_password"] == nil)
    }

    @Test func directoryProtectionWriteParameters() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_directoryprotection", returnInfo: "TRUE"),
            KASFixtures.mapArrayResponse("get_directoryprotection", items: []),
            KASFixtures.scalarResponse("delete_directoryprotection", returnInfo: "TRUE"),
            KASFixtures.scalarResponse("delete_directoryprotection", returnInfo: "TRUE"),
        ])
        let dp = try await adapter.createDirectoryProtection(path: "/example.com/intern/", username: "Max", password: "Dir-geheim", realm: "Intern")
        #expect(dp.users == ["Max"])
        #expect(dp.realm == "Intern")
        try await adapter.deleteDirectoryProtection(path: "/example.com/intern/", username: "Max")
        try await adapter.deleteDirectoryProtection(path: "/example.com/intern/", username: nil)
        let requests = await transport.requests
        #expect(requests[1].requestParams == [
            "directory_path": "/example.com/intern/", "directory_user": "Max", "directory_password": "Dir-geheim", "directory_authname": "Intern",
        ])
        #expect(requests[3].requestParams == ["directory_path": "/example.com/intern/", "directory_user": "Max"])
        #expect(requests[4].requestParams == ["directory_path": "/example.com/intern/"])
    }

    // MARK: - Subaccount (ohne Fixture)

    @Test func subaccountBestEffortMapping() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.mapArrayResponse("get_accounts", items: [["account_login": "w01sub01", "account_comment": "Kunde A", "account_password": "x", "account_ftp": "Y"]]),
            KASFixtures.scalarResponse("add_account", returnInfo: "w01sub02"),
            KASFixtures.mapArrayResponse("get_accounts", items: [["account_login": "w01sub02", "account_comment": "Kunde B"]]),
            KASFixtures.scalarResponse("delete_account", returnInfo: "TRUE"),
        ])
        let accounts = try await adapter.listSubaccounts()
        #expect(accounts.map(\.login) == ["w01sub01"])
        #expect(accounts.first?.comment == "Kunde A")
        #expect(accounts.first?.extra["account_ftp"] == .string("Y"))
        #expect(accounts.first?.extra["account_password"] == nil)

        let created = try await adapter.createSubaccount(password: "Sub-geheim", comment: "Kunde B", extra: ["account_ftp": .string("N")])
        #expect(created.login == "w01sub02")
        #expect(created.comment == "Kunde B")
        try await adapter.deleteSubaccount(login: "w01sub02")
        let requests = await transport.requests
        #expect(requests[2].requestParams == ["account_password": "Sub-geheim", "account_comment": "Kunde B", "account_ftp": "N"])
        #expect(requests.last?.requestParams == ["account_login": "w01sub02"])
    }
}

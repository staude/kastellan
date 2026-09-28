import Foundation
import Testing
@testable import KastellanCore

struct MittwaldInventoryTests {
    static let project = "11111111-1111-4111-8111-111111111111"
    static let settings = ["project_id": project]

    static func page(_ items: [String]) -> MittwaldResponse { MittwaldFixtures.page(items, total: items.count) }
    static func pageFrom(_ fixture: String) throws -> MittwaldResponse {
        let text = String(data: try MittwaldFixtures.data(fixture), encoding: .utf8)!
        return MittwaldFixtures.json(text, headers: ["X-Pagination-TotalCount": "2"])
    }

    @Test func serversMapMachineType() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([Self.page([#"{"id":"s-1","shortId":"s-abc","description":"Web","status":"ready","clusterName":"espelkamp","machineType":{"name":"shared.large","cpu":"2","memory":"4Gi"},"storage":"50Gi","createdAt":"2026-01-01T00:00:00Z","customerId":"c-1"}"#])], settings: ["customer_id": "c-1"])
        let servers = try await adapter.listServers()
        #expect(servers.count == 1)
        #expect(servers[0].name == "Web")
        #expect(servers[0].status == "ready")
        #expect(servers[0].type == "shared.large")
        #expect(servers[0].location == "espelkamp")
        #expect(await transport.requests[0].query["customerId"] == "c-1")
        await #expect(throws: KastellanError.self) { try await adapter.updateServer(providerRef: "s-1", name: nil, labels: nil, power: .reboot) }
    }

    @Test func domainsMapNameserversAndProcesses() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([Self.page([
            #"{"domainId":"d-1","domain":"example.com","projectId":"p","nameservers":["ns1.mittwald.de","ns2.mittwald.de"],"usesDefaultNameserver":true,"connected":true,"deleted":false,"processes":[{"processType":"TRANSFER","state":"REQUESTED","status":"waiting","transactionId":"t"}],"authCode":{"value":"x","expires":"2026-10-01T00:00:00Z"}}"#,
            #"{"domainId":"d-2","domain":"example.net","projectId":"p","nameservers":["ns.example.org"],"usesDefaultNameserver":false,"connected":false,"deleted":false,"processes":[]}"#,
        ])], settings: Self.settings)
        let domains = try await adapter.listDomains()
        #expect(domains.map(\.fqdn) == ["example.com", "example.net"])
        #expect(domains[0].dnsManagedHere)
        #expect(domains[0].status == "active")
        #expect(domains[1].status == "not_connected")
        #expect(domains[0].extra["processes"] == .array([.object(["type": .string("TRANSFER"), "state": .string("REQUESTED"), "status": .string("waiting")])]))
        #expect(await transport.requests[0].query["projectId"] == Self.project)
    }

    @Test func ingressesBecomeSubdomains() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([Self.page([
            #"{"id":"i-1","hostname":"app.example.com","projectId":"p","isDefault":false,"isDomain":false,"isEnabled":true,"ips":{"v4":["192.0.2.1"],"v6":[]},"ownership":{"verified":true},"paths":[{"path":"/","target":{"installationId":"a-1"}}],"tls":{"acme":true,"isCreated":true}}"#,
            #"{"id":"i-2","hostname":"go.example.com","projectId":"p","isDefault":false,"isDomain":false,"isEnabled":true,"ips":{"v4":[],"v6":[]},"ownership":{"verified":false,"txtRecord":"mittwald-verify=abc"},"paths":[{"path":"/","target":{"url":"https://example.org/"}}],"tls":{"acme":true,"isCreated":false}}"#,
            #"{"id":"i-3","hostname":"example.com","projectId":"p","isDefault":true,"isDomain":true,"isEnabled":true,"ips":{"v4":[],"v6":[]},"ownership":{"verified":true},"paths":[{"path":"/","target":{"useDefaultPage":true}}],"tls":{"acme":true,"isCreated":true}}"#,
        ])], settings: Self.settings)
        let subs = try await adapter.listSubdomains(parent: "example.com")
        #expect(subs.map(\.fqdn) == ["app.example.com", "go.example.com"])
        #expect(subs[0].targetPath == "app:a-1")
        #expect(subs[0].parent == "example.com")
        #expect(subs[1].redirect == "https://example.org/")
        #expect(subs[1].extra["ownership"]?.string("txtRecord") == "mittwald-verify=abc")
    }

    @Test func dnsZoneSplitsRecordSetsIntoRecords() async throws {
        let zoneText = String(data: try MittwaldFixtures.data("dns-zone"), encoding: .utf8)!
        let (adapter, transport, _) = MittwaldFixtures.adapter([Self.page([zoneText]), Self.page([zoneText]), Self.page([zoneText])], settings: Self.settings)
        let zones = try await adapter.listZones()
        #expect(zones.count == 1)
        #expect(zones[0].zone == "example.com")
        #expect(zones[0].extra["a_managed"] == .bool(true))
        #expect(await transport.requests[0].path == "/projects/\(Self.project)/dns-zones")

        let records = try await adapter.listRecords(zone: "Example.com")
        #expect(records.map(\.type) == ["MX", "MX", "TXT", "TXT", "SRV", "CAA"])
        #expect(records[0].content == "mx1.example.net" && records[0].priority == 10 && records[0].ttl == 3600)
        #expect(records[0].ref.providerRef == "z1111111-1111-4111-8111-111111111111/MX/0")
        #expect(records[2].content == "_kastellan=probe" && records[2].ttl == nil)
        #expect(records[4].content == "5 5060 sip.example.com" && records[4].priority == 10)
        #expect(records[5].content == "0 issue \"letsencrypt.org\"")
        #expect(records.allSatisfy { $0.name == "@" })
        await #expect(throws: KastellanError.notFound("DNS-Zone nope.example bei Mittwald")) {
            _ = try await adapter.listRecords(zone: "nope.example")
        }
    }

    @Test func mailAddressesSplitIntoMailboxesForwardsAndAutoresponder() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([try Self.pageFrom("mail-addresses"), try Self.pageFrom("mail-addresses"), try Self.pageFrom("mail-addresses"), try Self.pageFrom("mail-addresses")], settings: Self.settings)
        let boxes = try await adapter.listMailboxes(domain: "example.com")
        #expect(boxes.count == 1)
        #expect(boxes[0].address == "user1@example.com")
        #expect(boxes[0].quotaMB == 1024)
        #expect(boxes[0].usedMB == 20)
        #expect(boxes[0].spamFilter == "on")
        #expect(boxes[0].copyTo == ["user2@example.net"])
        #expect(boxes[0].extra["mailbox_name"] == .string("p-aaaaa1-abc12"))

        let forwards = try await adapter.listForwards(domain: nil)
        #expect(forwards.map(\.address) == ["info@example.com", "user1@example.com"])
        #expect(forwards[0].targets == ["user1@example.com", "user3@example.org"])
        #expect(!forwards[0].keepCopy)
        #expect(forwards[1].keepCopy)

        let box = try await adapter.getMailbox(address: "USER1@example.com")
        #expect(box?.ref.providerRef == "m1111111-1111-4111-8111-111111111111")

        let responder = try await adapter.getAutoresponder(address: "user1@example.com")
        #expect(responder?.active == true)
        #expect(responder?.text == "Bin bis Montag nicht da.")
        #expect(responder?.until == MittwaldDates.date("2026-09-14T00:00:00Z"))
    }

    @Test func databasesIncludeMainUserAndRedis() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([
            Self.page([#"{"id":"db-1","name":"mysql_abc12","description":"Shop","hostname":"mysql-abc12.project.host","externalHostname":"mysql-abc12.example.host","version":"8.0","status":"ready","projectId":"p","mainUser":{"id":"u-1","name":"dbu_abc12","status":"ready","accessLevel":"full","mainUser":true},"storageUsageInBytes":1024}"#]),
            Self.page([#"{"id":"r-1","name":"redis_abc12","description":"Cache","hostname":"redis-abc12.project.host","port":6379,"version":"7","status":"ready","projectId":"p"}"#]),
        ], settings: Self.settings)
        let dbs = try await adapter.listDatabases()
        #expect(dbs.map(\.name) == ["mysql_abc12", "redis_abc12"])
        #expect(dbs[0].engine == "mysql")
        #expect(dbs[0].users == ["dbu_abc12"])
        #expect(dbs[0].host == "mysql-abc12.project.host")
        #expect(dbs[0].comment == "Shop")
        #expect(dbs[1].engine == "redis")
        #expect(dbs[1].extra["port"] == .int(6379))
    }

    @Test func sshAndSftpUsersAndCronjobs() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([
            Self.page([#"{"id":"ssh-1","userName":"ssh-abc12@p-aaaaa1","description":"Deploy","active":true,"hasPassword":false,"projectId":"p","publicKeys":[{"key":"ssh-ed25519 AAAA1 a","comment":"a"},{"key":"ssh-ed25519 AAAA2 b","comment":"b"}]}"#]),
            Self.page([#"{"id":"sftp-1","userName":"sftp-abc12@p-aaaaa1","description":"Upload","active":true,"hasPassword":true,"accessLevel":"full","directories":["/html/app"],"projectId":"p","publicKeys":[]}"#]),
            Self.page([#"{"id":"cj-1","shortId":"c-1","description":"Aufräumen","interval":"0 3 * * *","active":true,"timeout":600,"appInstallationId":"a-1","projectId":"p","target":{"appInstallationId":"a-1","destination":{"interpreter":"/usr/bin/php","path":"/html/cron.php","parameters":"--quiet"}},"latestExecution":{"status":"Complete","successful":true,"start":"2026-09-09T03:00:00Z"}}"#,
                       #"{"id":"cj-2","shortId":"c-2","description":"Ping","interval":"*/5 * * * *","active":false,"timeout":60,"appInstallationId":"a-1","projectId":"p","target":{"appInstallationId":"a-1","destination":{"url":"https://app.example.com/cron"}}}"#]),
        ], settings: Self.settings)
        let ssh = try await adapter.listSSHUsers()
        #expect(ssh[0].username == "ssh-abc12@p-aaaaa1")
        #expect(ssh[0].publicKeys.count == 2)
        let sftp = try await adapter.listFTPUsers()
        #expect(sftp[0].homePath == "/html/app")
        #expect(sftp[0].extra["protocol"] == .string("sftp"))
        let jobs = try await adapter.listCronJobs()
        #expect(jobs[0].schedule == "0 3 * * *")
        #expect(jobs[0].command == "/usr/bin/php /html/cron.php --quiet")
        #expect(jobs[0].extra["latestExecution"]?.string("status") == "Complete")
        #expect(jobs[1].url == "https://app.example.com/cron")
        #expect(!jobs[1].active)
    }

    @Test func certificatesAndMemberships() async throws {
        let (adapter, _, _) = MittwaldFixtures.adapter([
            Self.page([#"{"id":"cert-1","commonName":"example.com","dnsNames":["example.com","www.example.com"],"issuer":"Let's Encrypt","certificateType":1,"validFrom":"2026-08-01T00:00:00Z","validTo":"2026-10-30T00:00:00Z","isExpired":false,"projectId":"p"}"#]),
            Self.page([#"{"id":"mem-1","userId":"u-1","email":"user1@example.com","firstName":"Erika","lastName":"Muster","role":"owner","inherited":false,"mfa":true,"projectId":"p","memberSince":"2026-01-01T00:00:00Z"}"#]),
            Self.page([#"{"id":"inv-1","mailAddress":"user9@example.org","role":"external","projectId":"p","membershipExpiresAt":"2026-12-31T00:00:00Z"}"#]),
        ], settings: Self.settings)
        let certs = try await adapter.listCertificates()
        #expect(certs[0].hostname == "example.com")
        #expect(certs[0].issuer == "Let's Encrypt")
        #expect(certs[0].autoRenew == true)
        #expect(certs[0].validUntil == MittwaldDates.date("2026-10-30T00:00:00Z"))
        #expect(certs[0].extra["certificateType"] == .string("internal"))
        let subs = try await adapter.listSubaccounts()
        #expect(subs.map(\.login) == ["user1@example.com", "user9@example.org"])
        #expect(subs[0].comment == "Erika Muster, owner")
        #expect(subs[1].extra["kind"] == .string("invite"))
    }

    @Test func listsSpanAllProjectsWithoutSetting() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            try MittwaldFixtures.ok("projects", headers: ["X-Pagination-TotalCount": "2"]),
            Self.page([#"{"id":"ssh-1","userName":"a","publicKeys":[]}"#]),
            Self.page([#"{"id":"ssh-2","userName":"b","publicKeys":[]}"#]),
        ])
        let ssh = try await adapter.listSSHUsers()
        #expect(ssh.map(\.username) == ["a", "b"])
        let requests = await transport.requests
        #expect(requests.map(\.path) == ["/projects", "/projects/11111111-1111-4111-8111-111111111111/ssh-users", "/projects/22222222-2222-4222-8222-222222222222/ssh-users"])
    }

    @Test func capabilitiesExcludeUnsupportedResources() {
        let m = MittwaldAdapter.capabilityMatrix
        #expect(m.supports(Capability(.dnsRecord, .list)))
        #expect(!m.supports(Capability(.dnsZone, .create)))
        #expect(m.supports(Capability(.server, .update)))
        #expect(!m.supports(Capability(.mailingList, .list)))
        #expect(!m.supports(Capability(.firewall, .list)))
    }
}

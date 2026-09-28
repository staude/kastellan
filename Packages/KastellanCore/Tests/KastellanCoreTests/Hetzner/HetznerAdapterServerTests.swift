import Foundation
import Testing
@testable import KastellanCore

struct HetznerAdapterServerTests {
    @Test func capabilityMatrixCoversServersKeysAndFirewalls() throws {
        let m = HetznerAdapter.capabilityMatrix
        for action in [Action.list, .get, .create, .update, .delete] {
            #expect(m.supports(Capability(.server, action)))
        }
        #expect(!m.supports(Capability(.server, .setPassword)))
        #expect(m.supports(Capability(.sshUser, .list)))
        #expect(m.supports(Capability(.sshUser, .create)))
        #expect(m.supports(Capability(.sshUser, .delete)))
        #expect(!m.supports(Capability(.sshUser, .update)))
        #expect(m.supports(Capability(.firewall, .list)))
        #expect(m.supports(Capability(.firewall, .get)))
        #expect(!m.supports(Capability(.firewall, .create)))
        #expect(m.resources == [.dnsZone, .dnsRecord, .server, .sshUser, .firewall])

        var registry = AdapterRegistry()
        registry.register(HetznerAdapter.self)
        let adapter = try registry.adapter(for: HetznerFixtures.connection(), secrets: InMemorySecretProvider())
        #expect(adapter as? any ServerAdapter != nil)
        #expect(adapter as? any SSHUserAdapter != nil)
        #expect(adapter as? any FirewallAdapter != nil)
    }

    // MARK: - Server

    @Test func listServersMapsFixture() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("servers")])
        let servers = try await adapter.listServers()
        #expect(await transport.requests.first?.path == "/servers")
        #expect(servers.map(\.name) == ["web-01", "build-01"])
        #expect(servers.map(\.ref.providerRef) == ["42", "43"])
        #expect(servers[0].ref.connectionID == "conn-hetzner")

        let web = servers[0]
        #expect(web.status == "running")
        #expect(web.ipv4 == "203.0.113.42")
        #expect(web.ipv6 == "2001:db8:42::/64")
        #expect(web.type == "cpx22")
        #expect(web.location == "fsn1")
        #expect(web.image == "ubuntu-24.04")
        #expect(web.labels == ["role": "web", "env": "prod"])
        #expect(web.createdAt == Date(timeIntervalSince1970: 1_755_246_600))
        #expect(web.extra["backup_window"] == .string("22-02"))
        #expect(web.extra["protection"] == .object(["delete": .bool(true), "rebuild": .bool(true)]))
        #expect(web.extra["primary_disk_size"] == .int(80))
        #expect(web.extra["locked"] == .bool(false))
        #expect(web.extra["server_type_description"] == .string("CPX22"))
        #expect(web.extra["os_flavor"] == .string("ubuntu"))
        #expect(web.extra["ipv4_dns_ptr"] == .string("web-01.example.com"))
        #expect(web.extra["private_ips"] == .array([.string("10.0.0.2")]))
        #expect(web.extra["datacenter"] == nil)

        // Zweiter Server: kein IPv4, Snapshot ohne Namen, altes `datacenter`-Feld als Rückfall.
        let build = servers[1]
        #expect(build.status == "off")
        #expect(build.ipv4 == nil)
        #expect(build.ipv6 == "2001:db8:43::/64")
        #expect(build.type == "cax11")
        #expect(build.location == "nbg1")
        #expect(build.image == "build-base 2025-08")
        #expect(build.labels.isEmpty)
        #expect(build.createdAt == Date(timeIntervalSince1970: 1_756_728_000))
        #expect(build.extra["datacenter"] == .string("nbg1-dc3"))
        #expect(build.extra["backup_window"] == nil)
        #expect(build.extra["private_ips"] == nil)
    }

    @Test func getServerReadsSingleServer() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("server-42")])
        let server = try #require(try await adapter.getServer(providerRef: "42"))
        #expect(server.name == "web-01")
        #expect(server.ipv4 == "203.0.113.42")
        #expect(await transport.requests.first?.path == "/servers/42")
    }

    @Test func getServerUnknownIsNil() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([HetznerFixtures.notFound("server")])
        #expect(try await adapter.getServer(providerRef: "999") == nil)
    }

    @Test func getServerOtherErrorsSurface() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([HetznerFixtures.error(403, code: "forbidden", message: "insufficient permissions")])
        await #expect(throws: KastellanError.unauthorized("forbidden: insufficient permissions")) {
            try await adapter.getServer(providerRef: "42")
        }
    }

    @Test func createServerPostsSpecAndWaitsForActions() async throws {
        let (adapter, transport, sleeps) = HetznerFixtures.adapter([
            try HetznerFixtures.ok("server-create"),
            HetznerFixtures.action(id: 2001, command: "create_server"),
            HetznerFixtures.action(id: 2002, command: "start_server"),
            HetznerFixtures.json(#"{"server":{"id":44,"name":"app-01","status":"running","created":"2025-09-06T09:00:00Z","public_net":{"ipv4":{"ip":"203.0.113.44","blocked":false,"dns_ptr":"x"},"ipv6":null,"floating_ips":[]},"server_type":{"name":"cpx22"},"location":{"name":"nbg1"},"image":{"name":"ubuntu-24.04"},"labels":{"env":"staging"},"protection":{"delete":false,"rebuild":false},"primary_disk_size":80}}"#),
        ])
        let spec = ServerSpec(name: "app-01", type: "cpx22", image: "ubuntu-24.04", location: "nbg1",
                              sshKeys: ["user@work"], labels: ["env": "staging"],
                              extra: ["user_data": .string("#cloud-config\n"), "ignored": .string("x")])
        let server = try await adapter.createServer(spec)
        #expect(server.ref.providerRef == "44")
        #expect(server.status == "running")
        #expect(server.ipv4 == "203.0.113.44")
        #expect(server.location == "nbg1")
        #expect(server.extra["root_password"] == .string("YItygq1v3GYjjMomLaKc"))

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["POST", "GET", "GET", "GET"])
        #expect(requests[0].path == "/servers")
        #expect(requests[0].body == .object([
            "name": .string("app-01"), "server_type": .string("cpx22"), "image": .string("ubuntu-24.04"),
            "location": .string("nbg1"), "ssh_keys": .array([.string("user@work")]),
            "labels": .object(["env": .string("staging")]), "start_after_create": .bool(true),
            "user_data": .string("#cloud-config\n"),
        ]))
        #expect(requests[1].path == "/actions/2001")
        #expect(requests[2].path == "/actions/2002")
        #expect(requests[3].path == "/servers/44")
        #expect(await sleeps.seconds == [1, 1])
    }

    @Test func createServerWithoutRootPasswordKeepsExtraClean() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([
            HetznerFixtures.json(#"{"server":{"id":44,"name":"app-01","status":"initializing"},"action":{"id":1,"command":"create_server","status":"success"},"next_actions":[]}"#),
            HetznerFixtures.json(#"{"server":{"id":44,"name":"app-01","status":"running","labels":{}}}"#),
        ])
        let server = try await adapter.createServer(ServerSpec(name: "app-01", type: "cpx22", image: "ubuntu-24.04"))
        #expect(server.extra["root_password"] == nil)
        #expect(server.status == "running")
    }

    @Test func createServerFailedActionIsProviderError() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([
            HetznerFixtures.json(#"{"server":{"id":44,"name":"app-01","status":"initializing"},"action":{"id":1,"command":"create_server","status":"error","error":{"code":"resource_unavailable","message":"server type not available"}},"next_actions":[],"root_password":"geheim"}"#),
        ])
        await #expect(throws: KastellanError.provider("create_server: resource_unavailable: server type not available")) {
            try await adapter.createServer(ServerSpec(name: "app-01", type: "cpx22", image: "ubuntu-24.04"))
        }
    }

    @Test func createServerRequiresNameTypeImage() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([])
        await #expect(throws: KastellanError.invalidArgument("Server braucht name, type und image")) {
            try await adapter.createServer(ServerSpec(name: "x", type: "", image: "ubuntu-24.04"))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func updateServerRenamesAndSetsLabels() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            try HetznerFixtures.ok("server-42"),
            try HetznerFixtures.ok("server-42"),
        ])
        let server = try await adapter.updateServer(providerRef: "42", name: "web-02", labels: ["role": "web"], power: nil)
        #expect(server.name == "web-01")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["PUT", "GET"])
        #expect(requests[0].path == "/servers/42")
        #expect(requests[0].body == .object(["name": .string("web-02"), "labels": .object(["role": .string("web")])]))
        #expect(requests[1].path == "/servers/42")
    }

    @Test func updateServerPowerOffPollsAction() async throws {
        let (adapter, transport, sleeps) = HetznerFixtures.adapter([
            HetznerFixtures.action(id: 13, command: "stop_server", status: "running"),
            HetznerFixtures.action(id: 13, command: "stop_server", status: "running"),
            HetznerFixtures.action(id: 13, command: "stop_server", status: "success"),
            try HetznerFixtures.ok("server-42"),
        ])
        let server = try await adapter.updateServer(providerRef: "42", name: nil, labels: nil, power: .powerOff)
        #expect(server.ref.providerRef == "42")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["POST", "GET", "GET", "GET"])
        #expect(requests[0].path == "/servers/42/actions/poweroff")
        #expect(requests[0].body == nil)
        #expect(requests[1].path == "/actions/13")
        #expect(requests[2].path == "/actions/13")
        #expect(requests[3].path == "/servers/42")
        #expect(await sleeps.seconds == [1, 1])
    }

    @Test func updateServerMapsAllPowerActions() async throws {
        let expected: [(ServerPowerAction, String)] = [(.powerOn, "poweron"), (.powerOff, "poweroff"), (.reboot, "reboot"), (.shutdown, "shutdown")]
        for (power, command) in expected {
            let (adapter, transport, _) = HetznerFixtures.adapter([
                HetznerFixtures.action(command: command),
                try HetznerFixtures.ok("server-42"),
            ])
            _ = try await adapter.updateServer(providerRef: "42", name: nil, labels: nil, power: power)
            #expect(await transport.requests.first?.path == "/servers/42/actions/\(command)")
        }
    }

    @Test func updateServerFailedPowerActionIsProviderError() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([
            HetznerFixtures.action(id: 13, command: "reboot_server", status: "error", error: ("locked", "server is locked")),
        ])
        await #expect(throws: KastellanError.provider("reboot_server: locked: server is locked")) {
            try await adapter.updateServer(providerRef: "42", name: nil, labels: nil, power: .reboot)
        }
    }

    @Test func updateServerWithNothingToDoJustReads() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("server-42")])
        _ = try await adapter.updateServer(providerRef: "42", name: nil, labels: nil, power: nil)
        #expect(await transport.requests.map(\.method) == ["GET"])
    }

    @Test func updateServerUnknownIsNotFound() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([HetznerFixtures.notFound("server")])
        await #expect(throws: KastellanError.notFound("Server 999")) {
            try await adapter.updateServer(providerRef: "999", name: nil, labels: nil, power: nil)
        }
    }

    @Test func deleteServerWaitsForAction() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            HetznerFixtures.action(id: 77, command: "delete_server", status: "running"),
            HetznerFixtures.action(id: 77, command: "delete_server", status: "success"),
        ])
        try await adapter.deleteServer(providerRef: "42")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["DELETE", "GET"])
        #expect(requests[0].path == "/servers/42")
        #expect(requests[1].path == "/actions/77")
    }

    @Test func deleteServerProtectedIsProviderError() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([HetznerFixtures.error(423, code: "protected", message: "server is delete protected")])
        await #expect(throws: KastellanError.provider("protected: server is delete protected")) {
            try await adapter.deleteServer(providerRef: "42")
        }
    }

    // MARK: - SSH-Keys

    @Test func listSSHUsersMapsKeys() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("ssh_keys")])
        let users = try await adapter.listSSHUsers()
        #expect(await transport.requests.first?.path == "/ssh_keys")
        #expect(users.map(\.username) == ["user@work", "deploy"])
        #expect(users.map(\.ref.providerRef) == ["2323", "2324"])
        #expect(users[0].publicKeys == ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyWork user@work"])
        #expect(users[0].extra["fingerprint"] == .string("b7:2f:30:a0:2f:6c:58:6c:21:04:58:61:ba:06:3b:2f"))
        #expect(users[0].extra["labels"] == .object(["owner": .string("Max")]))
        #expect(users[0].extra["id"] == .int(2323))
        #expect(users[1].extra["labels"] == .object([:]))
    }

    @Test func createSSHUserPostsNamedKey() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("ssh_key-create")])
        let user = try await adapter.createSSHUser(username: "kastellan-20260906", publicKeys: ["  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyNew kastellan\n"])
        #expect(user.username == "kastellan-20260906")
        #expect(user.ref.providerRef == "2325")
        #expect(user.publicKeys.count == 1)
        #expect(user.extra["also_created"] == nil)
        let req = try #require(await transport.requests.first)
        #expect(req.method == "POST")
        #expect(req.path == "/ssh_keys")
        #expect(req.body == .object([
            "name": .string("kastellan-20260906"),
            "public_key": .string("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyNew kastellan"),
        ]))
    }

    @Test func createSSHUserWithoutNameUsesDatedDefault() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("ssh_key-create")])
        _ = try await adapter.createSSHUser(username: nil, publicKeys: ["ssh-ed25519 AAAA test"])
        let name = try #require(await transport.requests.first?.body?.string("name"))
        #expect(name.hasPrefix("kastellan-"))
        #expect(name.count == "kastellan-20260906".count)
        #expect(HetznerAdapter.defaultKeyName(date: Date(timeIntervalSince1970: 1_788_998_400)) == "kastellan-20260910")
    }

    @Test func createSSHUserWithSeveralKeysCreatesSeveralEntries() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            HetznerFixtures.json(#"{"ssh_key":{"id":1,"name":"team","fingerprint":"aa","public_key":"ssh-ed25519 AAAA one","labels":{},"created":"2026-09-06T10:00:00Z"}}"#),
            HetznerFixtures.json(#"{"ssh_key":{"id":2,"name":"team-2","fingerprint":"bb","public_key":"ssh-ed25519 AAAA two","labels":{},"created":"2026-09-06T10:00:01Z"}}"#),
        ])
        let user = try await adapter.createSSHUser(username: "team", publicKeys: ["ssh-ed25519 AAAA one", "", "ssh-ed25519 AAAA two"])
        #expect(user.username == "team")
        #expect(user.ref.providerRef == "1")
        #expect(user.extra["also_created"] == .array([.string("team-2")]))
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].body?.string("name") == "team")
        #expect(requests[1].body?.string("name") == "team-2")
        #expect(requests[1].body?.string("public_key") == "ssh-ed25519 AAAA two")
    }

    @Test func createSSHUserWithoutKeysIsInvalid() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([])
        await #expect(throws: KastellanError.invalidArgument("public_keys ist leer")) {
            try await adapter.createSSHUser(username: "x", publicKeys: ["  "])
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func deleteSSHUserLooksUpByName() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            HetznerFixtures.json(#"{"ssh_keys":[{"id":2324,"name":"deploy","fingerprint":"x","public_key":"ssh-ed25519 AAAA","labels":{},"created":"2025-08-21T09:00:00Z"}],"meta":{"pagination":{"page":1,"per_page":25,"previous_page":null,"next_page":null,"last_page":1,"total_entries":1}}}"#),
            HetznerFixtures.empty(),
        ])
        try await adapter.deleteSSHUser(username: "deploy")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "DELETE"])
        #expect(requests[0].path == "/ssh_keys")
        #expect(requests[0].query == ["name": "deploy"])
        #expect(requests[1].path == "/ssh_keys/2324")
    }

    @Test func deleteSSHUserUnknownIsNotFound() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            HetznerFixtures.json(#"{"ssh_keys":[],"meta":{"pagination":{"page":1,"per_page":25,"previous_page":null,"next_page":null,"last_page":1,"total_entries":0}}}"#),
        ])
        await #expect(throws: KastellanError.notFound("SSH-Key nobody")) {
            try await adapter.deleteSSHUser(username: "nobody")
        }
        #expect(await transport.requests.count == 1)
    }

    // MARK: - Firewalls

    @Test func listFirewallsMapsRulesAndTargets() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([try HetznerFixtures.ok("firewalls")])
        let firewalls = try await adapter.listFirewalls()
        #expect(await transport.requests.first?.path == "/firewalls")
        #expect(firewalls.map(\.name) == ["web-ingress", "empty"])
        #expect(firewalls.map(\.ref.providerRef) == ["38", "39"])

        let fw = firewalls[0]
        #expect(fw.labels == ["env": "prod"])
        #expect(fw.rules.count == 4)
        #expect(fw.rules[0] == FirewallRule(direction: "in", protocolName: "tcp", port: "22",
                                            sources: ["198.51.100.0/24", "2001:db8:ff00:42::/64"], destinations: [], description: "SSH aus dem Büro"))
        #expect(fw.rules[1].port == "80-443")
        #expect(fw.rules[1].description == nil)
        #expect(fw.rules[2].protocolName == "icmp")
        #expect(fw.rules[2].port == nil)
        #expect(fw.rules[3].direction == "out")
        #expect(fw.rules[3].destinations == ["0.0.0.0/0", "::/0"])
        #expect(fw.appliedTo == ["server:42", "label_selector:env=prod"])
        #expect(fw.extra["applied_servers"] == .array([.string("42"), .string("45")]))
        #expect(fw.extra["created"] == .string("2025-08-10T07:00:00Z"))

        #expect(firewalls[1].rules.isEmpty)
        #expect(firewalls[1].appliedTo.isEmpty)
        #expect(firewalls[1].extra["applied_servers"] == nil)
    }

    @Test func getFirewallReadsSingleFirewall() async throws {
        let (adapter, transport, _) = HetznerFixtures.adapter([
            HetznerFixtures.json(#"{"firewall":{"id":38,"name":"web-ingress","labels":{},"created":"2025-08-10T07:00:00Z","rules":[{"direction":"in","protocol":"tcp","port":"22","source_ips":["0.0.0.0/0"],"destination_ips":[],"description":null}],"applied_to":[{"type":"server","server":{"id":42}}]}}"#),
        ])
        let fw = try #require(try await adapter.getFirewall(providerRef: "38"))
        #expect(fw.name == "web-ingress")
        #expect(fw.rules.count == 1)
        #expect(fw.appliedTo == ["server:42"])
        #expect(await transport.requests.first?.path == "/firewalls/38")
    }

    @Test func getFirewallUnknownIsNil() async throws {
        let (adapter, _, _) = HetznerFixtures.adapter([HetznerFixtures.notFound("firewall")])
        #expect(try await adapter.getFirewall(providerRef: "999") == nil)
    }
}

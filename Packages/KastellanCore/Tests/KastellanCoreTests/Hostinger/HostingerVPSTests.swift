import Foundation
import Testing
@testable import KastellanCore

struct HostingerVPSTests {
    static func vm(id: Int = 42, state: String = "running", hostname: String = "srv-1.example.com") -> String {
        #"{"id":\#(id),"firewall_group_id":7,"subscription_id":"sub-1","data_center_id":3,"plan":"KVM 2","hostname":"\#(hostname)","state":"\#(state)","actions_lock":"unlocked","cpus":2,"memory":8192,"disk":100,"bandwidth":8000,"ns1":"ns1.example.net","ns2":"ns2.example.net","ipv4":[{"id":1,"address":"192.0.2.30","ptr":"srv-1.example.com"}],"ipv6":[{"id":2,"address":"2001:db8::30"}],"template":{"id":1,"name":"Ubuntu 24.04"},"created_at":"2026-03-01T10:00:00Z"}"#
    }
    static let firewall = #"{"id":7,"name":"web","is_synced":true,"rules":[{"id":1,"action":"accept","protocol":"SSH","port":"22","source":"custom","source_detail":"203.0.113.0/24"},{"id":2,"action":"accept","protocol":"HTTPS","port":"443","source":"any","source_detail":""}],"created_at":"2026-03-01T10:00:00Z","updated_at":"2026-03-02T10:00:00Z"}"#

    @Test func listServersMapsAddressesAndPlan() async throws {
        let (adapter, _, _) = HostingerFixtures.adapter([HostingerFixtures.json("[\(Self.vm()),\(Self.vm(id: 43, state: "stopped", hostname: "db-1.example.com"))]")])
        let servers = try await adapter.listServers()
        #expect(servers.map(\.name) == ["db-1.example.com", "srv-1.example.com"])
        #expect(servers[1].status == "running")
        #expect(servers[1].ipv4 == "192.0.2.30")
        #expect(servers[1].ipv6 == "2001:db8::30")
        #expect(servers[1].type == "KVM 2")
        #expect(servers[1].image == "Ubuntu 24.04")
        #expect(servers[1].ref.providerRef == "42")
        #expect(servers[1].extra["actions_lock"] == .string("unlocked"))
    }

    @Test func powerActionsPollActionThenReload() async throws {
        let (adapter, transport, sleeps) = HostingerFixtures.adapter([
            HostingerFixtures.action(id: 9, name: "stop", state: "created"),
            HostingerFixtures.action(id: 9, name: "stop", state: "success"),
            HostingerFixtures.json(Self.vm(state: "stopped")),
        ])
        let server = try await adapter.updateServer(providerRef: "42", name: nil, labels: nil, power: .shutdown)
        #expect(server.status == "stopped")
        let requests = await transport.requests
        #expect(requests.map(\.path) == ["/api/vps/v1/virtual-machines/42/stop", "/api/vps/v1/virtual-machines/42/actions/9", "/api/vps/v1/virtual-machines/42"])
        #expect(await sleeps.seconds == [2])
        await #expect(throws: KastellanError.self) { try await adapter.updateServer(providerRef: "42", name: nil, labels: ["a": "b"], power: nil) }
        await #expect(throws: KastellanError.self) { try await adapter.deleteServer(providerRef: "42") }
    }

    @Test func renameUsesHostnameEndpoint() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([HostingerFixtures.action(id: 3, name: "hostname", state: "success"), HostingerFixtures.json(Self.vm(hostname: "neu.example.com"))])
        let server = try await adapter.updateServer(providerRef: "42", name: "neu.example.com", labels: nil, power: nil)
        #expect(server.name == "neu.example.com")
        let req = await transport.requests[0]
        #expect(req.method == "PUT" && req.path == "/api/vps/v1/virtual-machines/42/hostname" && req.body == .object(["hostname": .string("neu.example.com")]))
    }

    @Test func firewallsMapRulesAndAppliedServers() async throws {
        let (adapter, _, _) = HostingerFixtures.adapter([
            HostingerFixtures.json("[\(Self.vm())]"),
            HostingerFixtures.page([Self.firewall], page: 1, perPage: 100, total: 1),
        ])
        let firewalls = try await adapter.listFirewalls()
        #expect(firewalls.count == 1)
        #expect(firewalls[0].name == "web")
        #expect(firewalls[0].rules.count == 2)
        #expect(firewalls[0].rules[0].protocolName == "SSH" && firewalls[0].rules[0].port == "22" && firewalls[0].rules[0].sources == ["203.0.113.0/24"])
        #expect(firewalls[0].rules[1].sources == ["any"])
        #expect(firewalls[0].appliedTo == ["42"])
        #expect(firewalls[0].extra["is_synced"] == .bool(true))
    }

    @Test func sshKeysListCreateDelete() async throws {
        let (adapter, transport, _) = HostingerFixtures.adapter([
            HostingerFixtures.page([#"{"id":5,"name":"laptop","key":"ssh-ed25519 AAAA1 laptop"}"#], page: 1, perPage: 100, total: 1),
            HostingerFixtures.json(#"{"id":6,"name":"deploy","key":"ssh-ed25519 AAAA2 ci"}"#),
            HostingerFixtures.page([#"{"id":5,"name":"laptop","key":"ssh-ed25519 AAAA1 laptop"}"#, #"{"id":6,"name":"deploy","key":"ssh-ed25519 AAAA2 ci"}"#], page: 1, perPage: 100, total: 2),
            HostingerFixtures.message(),
        ])
        let keys = try await adapter.listSSHUsers()
        #expect(keys[0].username == "laptop" && keys[0].publicKeys == ["ssh-ed25519 AAAA1 laptop"])
        let created = try await adapter.createSSHUser(username: "deploy", publicKeys: ["ssh-ed25519 AAAA2 ci"])
        #expect(created.ref.providerRef == "6")
        #expect(await transport.requests[1].body == .object(["name": .string("deploy"), "key": .string("ssh-ed25519 AAAA2 ci")]))
        try await adapter.deleteSSHUser(username: "deploy")
        let del = await transport.requests[3]
        #expect(del.method == "DELETE" && del.path == "/api/vps/v1/public-keys/6")
        #expect(HostingerAdapter.capabilityMatrix.supports(Capability(.firewall, .list)))
        #expect(!HostingerAdapter.capabilityMatrix.supports(Capability(.server, .create)))
    }
}

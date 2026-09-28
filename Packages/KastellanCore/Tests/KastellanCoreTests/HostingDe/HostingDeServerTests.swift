import Foundation
import Testing
@testable import KastellanCore

struct HostingDeServerTests {
    static func vm(id: String = "vm-1", name: String = "web-1", status: String = "active", power: String = "on", ip: String = "192.0.2.50") -> JSONValue {
        .object(["id": .string(id), "accountId": .string("acc-42"), "name": .string(name), "description": .string("Webserver"), "productCode": .string("machine-virtualmachine-small-v2-1m"),
                 "memory": .int(2048), "cpuNumber": .int(2), "architecture": .string("x86_64"), "ipAddress": .string("2001:db8::10"), "status": .string(status), "power": .string(power), "rescue": .string("off"),
                 "rdns": .string("web-1.example.com"),
                 "networkInterfaces": .array([.object(["mac": .string("1a:01:b7:4e:32:d3"), "driver": .string("virtio"), "ipAddresses": .array(
                    (ip.isEmpty ? [] : [JSONValue.object(["ip": .string(ip), "type": .string("v4"), "primary": .bool(true), "netmask": .string("24")])])
                    + [.object(["ip": .string("2001:db8::10"), "type": .string("v6"), "primary": .bool(false)]), .object(["ip": .string("2001:db8::11"), "type": .string("v6"), "primary": .bool(false)])])])]), "paidUntil": .string("2027-01-01T00:00:00Z"),
                 "addDate": .string("2026-03-01T10:00:00Z"), "lastChangeDate": .string("2026-03-01T10:00:00Z")])
    }

    static func page(_ values: [JSONValue]) throws -> HostingDeResponse {
        HostingDeFixtures.page(try values.map { String(data: try JSONCoding.encoder.encode($0), encoding: .utf8)! }, page: 1, totalPages: 1)
    }

    static func objectResponse(_ value: JSONValue, pending: Bool = false) throws -> HostingDeResponse {
        let text = String(data: try JSONCoding.encoder.encode(value), encoding: .utf8)!
        return HostingDeFixtures.json(#"{"status":"\#(pending ? "pending" : "success")","errors":[],"warnings":[],"metadata":{},"response":\#(text)}"#)
    }

    @Test func listServersMapsPowerIntoStatus() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try Self.page([Self.vm(), Self.vm(id: "vm-2", name: "db-1", power: "off"), Self.vm(id: "vm-3", name: "neu", status: "creating", power: "off", ip: "")])])
        let servers = try await adapter.listServers()
        #expect(servers.map(\.name) == ["db-1", "neu", "web-1"])
        #expect(servers.map(\.status) == ["off", "creating", "running"])
        #expect(servers[2].ipv4 == "192.0.2.50")
        #expect(servers[2].ipv6 == "2001:db8::10")
        #expect(servers[1].ipv4 == nil)
        #expect(servers[1].ipv6 == "2001:db8::10")
        #expect(servers[2].type == "machine-virtualmachine-small-v2-1m")
        #expect(servers[2].createdAt == HostingDeDates.date("2026-03-01T10:00:00Z"))
        #expect(servers[2].extra["memory"] == .int(2048))
        #expect(servers[2].extra["rdns"] == .string("web-1.example.com"))
    }

    @Test func getServerByIdOrName() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.page([Self.vm()]), try Self.page([])])
        let found = try await adapter.getServer(providerRef: "vm-1")
        #expect(found?.name == "web-1")
        #expect(await transport.requests[0].param("filter") == HostingDeFilter.or([.equal("VirtualMachineId", "vm-1"), .equal("VirtualMachineName", "vm-1")]).json)
        #expect(try await adapter.getServer(providerRef: "nix") == nil)
    }

    @Test func createServerSendsProductAndWaits() async throws {
        let (adapter, transport, sleeps) = HostingDeFixtures.adapter([
            try Self.objectResponse(Self.vm(id: "vm-9", name: "neu", status: "creating", power: "off", ip: ""), pending: true),
            try Self.page([Self.vm(id: "vm-9", name: "neu", status: "creating", power: "off", ip: "")]),
            try Self.page([Self.vm(id: "vm-9", name: "neu", status: "active", power: "off")]),
        ])
        let server = try await adapter.createServer(ServerSpec(name: "neu", type: "", image: "debian-12", location: nil, sshKeys: [], labels: ["env": "test"], extra: [:]))
        #expect(server.ref.providerRef == "vm-9")
        #expect(server.status == "off")
        #expect(server.extra["note"] != nil)
        let vm = try #require(await transport.requests[0].param("virtualMachine"))
        #expect(vm.string("productCode") == "machine-virtualmachine-small-v2-1m")
        #expect(vm.string("name") == "neu")
        #expect(vm.string("description") == "env=test")
        #expect(vm["backupEnabled"] == .bool(false))
        #expect(await sleeps.seconds == [1])
    }

    @Test func powerActionsWaitForPowerState() async throws {
        let (adapter, transport, sleeps) = HostingDeFixtures.adapter([
            try Self.page([Self.vm(power: "on")]),
            try Self.objectResponse(Self.vm(power: "on")),
            try Self.page([Self.vm(power: "on")]),
            try Self.page([Self.vm(power: "on")]),
            try Self.page([Self.vm(power: "off")]),
        ])
        let server = try await adapter.updateServer(providerRef: "vm-1", name: nil, labels: nil, power: .shutdown)
        #expect(server.status == "off")
        #expect(server.extra["note"] == nil)
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["machine/virtualMachinesFind", "machine/virtualMachineShutdown", "machine/virtualMachinesFind", "machine/virtualMachinesFind", "machine/virtualMachinesFind"])
        #expect(requests[1].param("virtualMachineId") == .string("vm-1"))
        #expect(await sleeps.seconds == [1, 2])
    }

    @Test func powerActionReportsWhenStateDoesNotChange() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.page([Self.vm(power: "on")]), try Self.objectResponse(Self.vm(power: "on"))])
        for _ in 0..<30 { await transport.enqueue(try Self.page([Self.vm(power: "on")])) }
        let server = try await adapter.updateServer(providerRef: "vm-1", name: nil, labels: nil, power: .shutdown)
        #expect(server.status == "running")
        #expect(server.extra["note"]?.stringValue?.contains("weiterhin power on") == true)
    }

    @Test func renameAndLabelsAreUnsupported() async throws {
        let (adapter, _, _) = HostingDeFixtures.adapter([try Self.page([Self.vm()]), try Self.page([Self.vm()])])
        await #expect(throws: KastellanError.self) { try await adapter.updateServer(providerRef: "vm-1", name: "anders", labels: nil, power: nil) }
        await #expect(throws: KastellanError.self) { try await adapter.updateServer(providerRef: "vm-1", name: nil, labels: ["a": "b"], power: nil) }
    }

    @Test func deleteServerUsesId() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([HostingDeFixtures.json(#"{"status":"pending","errors":[],"warnings":[],"metadata":{},"response":null}"#)])
        try await adapter.deleteServer(providerRef: "vm-1")
        #expect(await transport.requests[0].method == "machine/virtualMachineDelete")
        #expect(await transport.requests[0].param("virtualMachineId") == .string("vm-1"))
    }

    @Test func subaccountsAreReadTolerantly() async throws {
        let (adapter, transport, _) = HostingDeFixtures.adapter([try Self.page([
            .object(["id": .string("acc-100"), "accountName": .string("kunde-a"), "status": .string("active"), "description": .string("Kunde A")]),
            .object(["id": .string("acc-101"), "name": .string("kunde-b")]),
        ])])
        let subs = try await adapter.listSubaccounts()
        #expect(subs.map(\.login) == ["kunde-a", "kunde-b"])
        #expect(subs[0].comment == "Kunde A")
        #expect(subs[0].ref.providerRef == "acc-100")
        #expect(subs[0].extra["status"] == .string("active"))
        #expect(await transport.requests[0].method == "account/subaccountsFind")
        await #expect(throws: KastellanError.self) { try await adapter.createSubaccount(password: "x", comment: nil, extra: [:]) }
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.subaccount, .list)))
        #expect(!HostingDeAdapter.capabilityMatrix.supports(Capability(.subaccount, .create)))
        #expect(HostingDeAdapter.capabilityMatrix.supports(Capability(.server, .update)))
    }
}

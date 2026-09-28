import Foundation

// VPS bei Hostinger: virtuelle Maschinen (`/api/vps/v1/virtual-machines`, Aktionen start, stop,
// restart liefern ein Action-Objekt, auf das der Client wartet), Firewalls als eigene Objekte mit
// Regeln (eine aktive je VM über `firewall_group_id`) und SSH-Schlüssel als Konto-Ressource
// (`/api/vps/v1/public-keys`, Zuordnung zu VMs über `attach`). Kauf und Kündigung laufen über das
// hPanel. `GET /virtual-machines/{id}/public-keys` liefert derzeit 404 (hostinger/api#58), deshalb
// werden nur die Konto-Schlüssel gelistet.

extension HostingerAdapter: ServerAdapter {
    static func firstAddress(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let s = value.stringValue { return s }
        if let list = value.arrayValue {
            for item in list {
                if let s = item.stringValue { return s }
                if let s = item.string("address") ?? item.string("ip") { return s }
            }
        }
        return value.string("address") ?? value.string("ip")
    }

    func server(_ item: JSONValue) -> Server {
        var extra = Self.extra(from: item, keys: ["actions_lock", "cpus", "memory", "disk", "bandwidth", "firewall_group_id", "subscription_id", "data_center_id", "ns1", "ns2", "template", "ipv4", "ipv6"])
        if let ptr = item["ipv4"]?.arrayValue?.first?.string("ptr") { extra["ptr"] = .string(ptr) }
        return Server(ref: ref(String(item.int("id") ?? 0)), name: item.string("hostname") ?? "", status: item.string("state") ?? "",
                      ipv4: Self.firstAddress(item["ipv4"]), ipv6: Self.firstAddress(item["ipv6"]), type: item.string("plan"),
                      location: item.int("data_center_id").map { "data-center \($0)" }, image: item["template"]?.string("name"),
                      labels: [:], createdAt: HostingerDates.date(item.string("created_at")), extra: extra)
    }

    public func listServers() async throws -> [Server] {
        try await client.list("/api/vps/v1/virtual-machines").map { server($0) }.sorted { $0.name < $1.name }
    }

    public func getServer(providerRef: String) async throws -> Server? {
        do { return server(try await client.get("/api/vps/v1/virtual-machines/\(providerRef)")) } catch KastellanError.notFound { return nil }
    }

    public func createServer(_ spec: ServerSpec) async throws -> Server {
        throw KastellanError.unsupported("Hostinger: VPS werden über den Kauf im hPanel angelegt, nicht über Kastellan")
    }

    public func updateServer(providerRef: String, name: String?, labels: [String: String]?, power: ServerPowerAction?) async throws -> Server {
        if labels != nil { throw KastellanError.unsupported("Hostinger: VPS haben keine Labels") }
        if let name, !name.isEmpty {
            let action = try await client.put("/api/vps/v1/virtual-machines/\(providerRef)/hostname", body: .object(["hostname": .string(name)]))
            if action.string("state") != nil { try await client.waitForAction(action, vm: providerRef) }
        }
        if let power {
            let path: String
            switch power {
            case .powerOn: path = "start"
            case .powerOff, .shutdown: path = "stop"
            case .reboot: path = "restart"
            }
            let action = try await client.post("/api/vps/v1/virtual-machines/\(providerRef)/\(path)")
            try await client.waitForAction(action, vm: providerRef)
        }
        return server(try await client.get("/api/vps/v1/virtual-machines/\(providerRef)"))
    }

    public func deleteServer(providerRef: String) async throws {
        throw KastellanError.unsupported("Hostinger: VPS werden über das Abonnement gekündigt, nicht über Kastellan")
    }
}

extension HostingerAdapter: FirewallAdapter {
    func firewall(_ item: JSONValue, servers: [JSONValue]) -> Firewall {
        let id = item.int("id") ?? 0
        let rules = item.array("rules").map { r in
            FirewallRule(direction: "in", protocolName: r.string("protocol") ?? "any", port: r.string("port"),
                         sources: [r.string("source") == "custom" ? (r.string("source_detail") ?? "") : "any"], destinations: [],
                         description: r.string("action").map { "\($0), Regel \(r.int("id") ?? 0)" })
        }
        let applied = servers.filter { $0.int("firewall_group_id") == id }.compactMap { $0.int("id").map(String.init) }
        var extra = Self.extra(from: item, keys: ["is_synced", "created_at", "updated_at"])
        extra["applied_hostnames"] = .array(servers.filter { $0.int("firewall_group_id") == id }.compactMap { $0.string("hostname").map { .string($0) } })
        return Firewall(ref: ref(String(id)), name: item.string("name") ?? "", rules: rules, appliedTo: applied, extra: extra)
    }

    public func listFirewalls() async throws -> [Firewall] {
        let servers = (try? await client.list("/api/vps/v1/virtual-machines")) ?? []
        return try await client.list("/api/vps/v1/firewall").map { firewall($0, servers: servers) }.sorted { $0.name < $1.name }
    }

    public func getFirewall(providerRef: String) async throws -> Firewall? {
        do {
            let item = try await client.get("/api/vps/v1/firewall/\(providerRef)")
            let servers = (try? await client.list("/api/vps/v1/virtual-machines")) ?? []
            return firewall(item, servers: servers)
        } catch KastellanError.notFound { return nil }
    }
}

extension HostingerAdapter: SSHUserAdapter {
    func sshKey(_ item: JSONValue) -> SSHUser {
        SSHUser(ref: ref(String(item.int("id") ?? 0)), username: item.string("name") ?? "", publicKeys: [item.string("key") ?? ""].filter { !$0.isEmpty },
                extra: ["scope": .string("account"), "note": .string("Konto-Schlüssel; Zuordnung zu einem VPS im hPanel oder beim Neuaufsetzen.")])
    }

    public func listSSHUsers() async throws -> [SSHUser] {
        try await client.list("/api/vps/v1/public-keys").map { sshKey($0) }.sorted { $0.username < $1.username }
    }

    public func createSSHUser(username: String?, publicKeys: [String]) async throws -> SSHUser {
        guard let key = publicKeys.first, !key.isEmpty else { throw KastellanError.invalidArgument("SSH-Schlüssel braucht einen öffentlichen Schlüssel") }
        var created: [SSHUser] = []
        for (i, k) in publicKeys.enumerated() {
            let base = username ?? k.split(separator: " ").dropFirst(2).joined(separator: " ")
            let name = publicKeys.count > 1 ? "\(base.isEmpty ? "Kastellan" : base) \(i + 1)" : (base.isEmpty ? "Kastellan" : base)
            created.append(sshKey(try await client.post("/api/vps/v1/public-keys", body: .object(["name": .string(name), "key": .string(k)]))))
        }
        var first = created[0]
        if created.count > 1 { first.extra["additional_keys"] = .array(created.dropFirst().map { .string($0.ref.providerRef) }) }
        _ = key
        return first
    }

    public func deleteSSHUser(username: String) async throws {
        let keys = try await client.list("/api/vps/v1/public-keys")
        guard let item = keys.first(where: { $0.string("name") == username || $0.int("id").map(String.init) == username }), let id = item.int("id") else {
            throw KastellanError.notFound("SSH-Schlüssel \(username) bei Hostinger")
        }
        try await client.delete("/api/vps/v1/public-keys/\(id)")
    }
}

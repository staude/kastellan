import Foundation

// Server über die Hetzner Cloud API (`/servers`). Anlegen, Löschen und Power-Aktionen sind
// asynchron: die Antwort enthält eine `action` (und beim Anlegen `next_actions`), auf die der
// Client bis `success` wartet. Danach wird der Server neu gelesen, damit Status und IPs stimmen.

extension HetznerAdapter: ServerAdapter {
    /// Schlüssel aus `ServerSpec.extra`, die unverändert an `POST /servers` gehen.
    static let createServerExtraKeys: Set<String> = [
        "user_data", "placement_group", "networks", "volumes", "firewalls", "public_net", "automount", "start_after_create",
    ]

    public func listServers() async throws -> [Server] {
        try await client.list("/servers", key: "servers").map { server($0) }
    }

    public func getServer(providerRef: String) async throws -> Server? {
        do {
            let response = try await client.get(Self.serverPath(providerRef))
            return response["server"].map { server($0) }
        } catch KastellanError.notFound(_) {
            return nil
        }
    }

    public func createServer(_ spec: ServerSpec) async throws -> Server {
        guard !spec.name.isEmpty, !spec.type.isEmpty, !spec.image.isEmpty else {
            throw KastellanError.invalidArgument("Server braucht name, type und image")
        }
        var body: [String: JSONValue] = [
            "name": .string(spec.name),
            "server_type": .string(spec.type),
            "image": .string(spec.image),
            "start_after_create": .bool(true),
        ]
        if let location = spec.location, !location.isEmpty { body["location"] = .string(location) }
        if !spec.sshKeys.isEmpty { body["ssh_keys"] = .array(spec.sshKeys.map { .string($0) }) }
        if !spec.labels.isEmpty { body["labels"] = .labels(spec.labels) }
        for (key, value) in spec.extra where Self.createServerExtraKeys.contains(key) { body[key] = value }

        let response = try await client.post("/servers", body: .object(body))
        try await client.waitForActions(in: response)
        guard let id = response["server"]?.int("id") else {
            throw KastellanError.provider("Hetzner: Antwort auf POST /servers enthält keinen Server")
        }
        var created = try await fetchServer(String(id))
        // Das Root-Passwort kommt nur mit, wenn kein SSH-Key angegeben wurde. Es steht hier
        // ein einziges Mal in `extra`; der Katalog legt es später im Schlüsselbund ab.
        if let password = response.string("root_password") {
            created.extra["root_password"] = .string(password)
        }
        return created
    }

    public func updateServer(providerRef: String, name: String?, labels: [String: String]?, power: ServerPowerAction?) async throws -> Server {
        var changes: [String: JSONValue] = [:]
        if let name, !name.isEmpty { changes["name"] = .string(name) }
        if let labels { changes["labels"] = .labels(labels) }
        if !changes.isEmpty {
            try await client.put(Self.serverPath(providerRef), body: .object(changes))
        }
        if let power {
            let response = try await client.post(Self.serverPath(providerRef) + "/actions/" + Self.actionName(power))
            try await client.waitForActions(in: response)
        }
        return try await fetchServer(providerRef)
    }

    public func deleteServer(providerRef: String) async throws {
        let response = try await client.delete(Self.serverPath(providerRef))
        try await client.waitForActions(in: response)
    }

    // MARK: - Mapping

    func server(_ item: JSONValue) -> Server {
        let publicNet = item["public_net"]
        let image = item["image"]
        var extra = Self.extra(from: item, keys: ["backup_window", "protection", "primary_disk_size", "locked", "rescue_enabled"])
        if let datacenter = item["datacenter"]?.string("name") { extra["datacenter"] = .string(datacenter) }
        if let description = item["server_type"]?.string("description") { extra["server_type_description"] = .string(description) }
        if let os = image?.string("os_flavor") { extra["os_flavor"] = .string(os) }
        if let ptr = publicNet?["ipv4"]?.string("dns_ptr") { extra["ipv4_dns_ptr"] = .string(ptr) }
        let privateIPs = item.array("private_net").compactMap { $0.string("ip") }
        if !privateIPs.isEmpty { extra["private_ips"] = .array(privateIPs.map { .string($0) }) }

        return Server(ref: ref(String(item.int("id") ?? 0)),
                      name: item.string("name") ?? "",
                      status: item.string("status") ?? "unknown",
                      ipv4: publicNet?["ipv4"]?.string("ip"),
                      ipv6: publicNet?["ipv6"]?.string("ip"),
                      type: item["server_type"]?.string("name"),
                      location: item["location"]?.string("name") ?? item["datacenter"]?["location"]?.string("name"),
                      image: image?.string("name") ?? image?.string("description"),
                      labels: item.labels(),
                      createdAt: HetznerDates.date(item.string("created")),
                      extra: extra)
    }

    // MARK: - Helfer

    private func fetchServer(_ providerRef: String) async throws -> Server {
        guard let server = try await getServer(providerRef: providerRef) else {
            throw KastellanError.notFound("Server \(providerRef)")
        }
        return server
    }

    static func serverPath(_ providerRef: String) -> String {
        "/servers/\(providerRef)"
    }

    /// Hetzner-Kommando zu einer Power-Aktion.
    static func actionName(_ power: ServerPowerAction) -> String {
        switch power {
        case .powerOn: "poweron"
        case .powerOff: "poweroff"
        case .reboot: "reboot"
        case .shutdown: "shutdown"
        }
    }
}

import Foundation

// Firewalls über die Hetzner Cloud API (`/firewalls`), nur lesend. Regeln werden 1:1 auf
// `FirewallRule` abgebildet, `applied_to` als `server:<id>` oder `label_selector:<selector>`.

extension HetznerAdapter: FirewallAdapter {
    public func listFirewalls() async throws -> [Firewall] {
        try await client.list("/firewalls", key: "firewalls").map { firewall($0) }
    }

    public func getFirewall(providerRef: String) async throws -> Firewall? {
        do {
            let response = try await client.get("/firewalls/\(providerRef)")
            return response["firewall"].map { firewall($0) }
        } catch KastellanError.notFound(_) {
            return nil
        }
    }

    // MARK: - Mapping

    func firewall(_ item: JSONValue) -> Firewall {
        let rules = item.array("rules").map { rule in
            FirewallRule(direction: rule.string("direction") ?? "in",
                         protocolName: rule.string("protocol") ?? "",
                         port: rule.string("port"),
                         sources: rule.strings("source_ips"),
                         destinations: rule.strings("destination_ips"),
                         description: rule.string("description"))
        }
        var appliedTo: [String] = []
        var appliedServers: [Int] = []
        for target in item.array("applied_to") {
            switch target.string("type") {
            case "server":
                if let id = target["server"]?.int("id") {
                    appliedTo.append("server:\(id)")
                    appliedServers.append(id)
                }
            case "label_selector":
                if let selector = target["label_selector"]?.string("selector") {
                    appliedTo.append("label_selector:\(selector)")
                }
                appliedServers += target.array("applied_to_resources").compactMap { $0["server"]?.int("id") }
            default:
                break
            }
        }
        var extra = Self.extra(from: item, keys: ["created"])
        var seen: Set<Int> = []
        let uniqueServers = appliedServers.filter { seen.insert($0).inserted }
        if !uniqueServers.isEmpty { extra["applied_servers"] = .array(uniqueServers.map { .string(String($0)) }) }
        return Firewall(ref: ref(String(item.int("id") ?? 0)),
                        name: item.string("name") ?? "",
                        rules: rules,
                        appliedTo: appliedTo,
                        labels: item.labels(),
                        extra: extra)
    }
}

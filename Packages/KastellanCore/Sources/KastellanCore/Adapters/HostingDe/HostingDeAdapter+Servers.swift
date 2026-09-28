import Foundation

// Virtuelle Maschinen (`machine`-Dienst) und Unterkonten (`account`-Dienst) bei hosting.de.
// VMs: `virtualMachinesFind`, `virtualMachineCreate` (Produktcode Pflicht, Bestellung),
// `virtualMachineDelete` (wiederherstellbar), Power über eigene Methoden mit `virtualMachineId`.
// Labels gibt es nicht, `description` ist das einzige freie Feld. Der `account`-Dienst ist
// öffentlich nicht dokumentiert; `subaccountsFind` wird tolerant gelesen (Felder wie `id`,
// `name`, `status`, `accountName` falls vorhanden), Anlegen und Löschen bleiben außen vor.
// Beim Praxistest prüfen: Produktcodes der VMs, Antwortform von `subaccountsFind`, ob
// `virtualMachineInstall` für ein Image nötig ist.

extension HostingDeAdapter: ServerAdapter {
    static let defaultServerProduct = "machine-virtualmachine-small-v2-1m"

    func server(_ item: JSONValue) -> Server {
        var extra = Self.extra(from: item, keys: ["productCode", "description", "memory", "cpuNumber", "architecture", "power", "rescue", "rdns",
                                                   "disks", "networkInterfaces", "paidUntil", "renewOn", "restorableUntil", "deletionScheduledFor", "lastChangeDate"])
        if let backup = item["backupEnabled"] { extra["backupEnabled"] = backup }
        let power = item.string("power") ?? ""
        let status = item.string("status") ?? ""
        // Kastellans `status` trägt den Betriebszustand, hosting.de trennt Vertrags- und Power-Status.
        let combined = status == "active" ? (power == "on" ? "running" : "off") : status
        // `ipAddress` ist in der Praxis nicht die IPv4 (bei einer echten VM stand dort eine IPv6);
        // die Adressen kommen aus den Netzwerk-Interfaces, primäre zuerst.
        let addresses = item.array("networkInterfaces").flatMap { $0.array("ipAddresses") }
            .sorted { ($0.bool("primary") ?? false) && !($1.bool("primary") ?? false) }
        let v4 = addresses.first { $0.string("type") == "v4" }?.string("ip")
        let v6 = addresses.first { $0.string("type") == "v6" }?.string("ip")
        let fallback = item.string("ipAddress")
        return Server(ref: ref(item.string("id") ?? ""), name: item.string("name") ?? "", status: combined,
                      ipv4: v4 ?? (fallback?.contains(":") == false ? fallback : nil), ipv6: v6 ?? (fallback?.contains(":") == true ? fallback : nil),
                      type: item.string("productCode"), location: nil, image: nil,
                      labels: [:], createdAt: HostingDeDates.date(item.string("addDate")), extra: extra)
    }

    public func listServers() async throws -> [Server] {
        try await client.findAll("machine", "virtualMachinesFind").map { server($0) }.sorted { $0.name < $1.name }
    }

    public func getServer(providerRef: String) async throws -> Server? {
        let filter = HostingDeFilter.or([.equal("VirtualMachineId", providerRef), .equal("VirtualMachineName", providerRef)])
        return try await client.findPage("machine", "virtualMachinesFind", filter: filter, limit: 1).data.first.map { server($0) }
    }

    public func createServer(_ spec: ServerSpec) async throws -> Server {
        guard !spec.name.isEmpty else { throw KastellanError.invalidArgument("Server braucht einen Namen") }
        let product = spec.type.isEmpty ? productCode(spec.extra, setting: "server_product", fallback: Self.defaultServerProduct) : spec.type
        let vm = JSONValue.compactObject([
            "name": .string(spec.name),
            "productCode": .string(product),
            "description": spec.extra["description"] ?? (spec.labels.isEmpty ? nil : .string(spec.labels.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))),
            "backupEnabled": spec.extra["backup_enabled"] ?? .bool(false),
        ])
        let result = try await client.call("machine", "virtualMachineCreate", ["virtualMachine": vm])
        var current = result.response
        if result.pending || current.string("status") != "active", let id = current.string("id") {
            current = try await waitForServer(id)
        }
        var created = server(current)
        if !spec.image.isEmpty {
            created.extra["note"] = .string("hosting.de installiert das Betriebssystem getrennt (virtualMachineInstall); das gewünschte Image \(spec.image) wurde nicht angewendet.")
        }
        return created
    }

    public func updateServer(providerRef: String, name: String?, labels: [String: String]?, power: ServerPowerAction?) async throws -> Server {
        guard let current = try await client.findPage("machine", "virtualMachinesFind", filter: .equal("VirtualMachineId", providerRef), limit: 1).data.first else {
            throw KastellanError.notFound("Server \(providerRef) bei hosting.de")
        }
        if let power {
            let method: String
            let expected: String
            switch power {
            case .powerOn: method = "virtualMachinePowerOn"; expected = "on"
            case .powerOff: method = "virtualMachinePowerOff"; expected = "off"
            case .shutdown: method = "virtualMachineShutdown"; expected = "off"
            case .reboot: method = "virtualMachineReboot"; expected = "on"
            }
            try await client.call("machine", method, ["virtualMachineId": .string(providerRef)])
            // Die Antwort kommt sofort; der Power-Zustand folgt nach. Bis `powerWait` warten, danach
            // den Stand melden, wie er ist (ein ACPI-Shutdown ohne Betriebssystem bleibt z. B. wirkungslos).
            let (latest, reached) = try await waitForPower(providerRef, expected: expected)
            var result = server(latest)
            if !reached {
                result.extra["note"] = .string("hosting.de meldet nach \(Int(Self.powerWait.components.seconds)) s weiterhin power \(latest.string("power") ?? "?"). Ein Shutdown wirkt nur mit laufendem Betriebssystem; power_off schaltet hart ab.")
            }
            return result
        }
        if let name, !name.isEmpty, name != current.string("name") {
            throw KastellanError.unsupported("hosting.de: VMs lassen sich über die API nicht umbenennen (kein virtualMachineUpdate)")
        }
        if labels != nil {
            throw KastellanError.unsupported("hosting.de: VMs haben keine Labels; Beschreibung nur im Kundenpanel änderbar")
        }
        let latest = current.string("status") == "active" ? current : try await waitForServer(providerRef)
        return server(latest)
    }

    /// Wartezeit auf den gewünschten Power-Zustand nach einer Power-Aktion.
    static let powerWait: Duration = .seconds(90)

    /// Pollt, bis `power` dem erwarteten Wert entspricht oder `powerWait` verstrichen ist.
    func waitForPower(_ id: String, expected: String) async throws -> (JSONValue, Bool) {
        let client = self.client
        do {
            let vm = try await client.waitUntilActive("Server \(id)", accepting: [], timeout: Self.powerWait) {
                let vm = try await client.findPage("machine", "virtualMachinesFind", filter: .equal("VirtualMachineId", id), limit: 1).data.first
                // `active` nur melden, wenn auch der Power-Zustand stimmt; sonst weiter warten.
                guard let vm, vm.string("power") == expected else {
                    var pending = vm?.objectValue ?? [:]
                    pending["status"] = .string("pending-power")
                    return .object(pending)
                }
                return vm
            }
            return (vm, true)
        } catch KastellanError.provider {
            guard let vm = try await client.findPage("machine", "virtualMachinesFind", filter: .equal("VirtualMachineId", id), limit: 1).data.first else {
                throw KastellanError.notFound("Server \(id) bei hosting.de")
            }
            return (vm, false)
        }
    }

    public func deleteServer(providerRef: String) async throws {
        try await client.call("machine", "virtualMachineDelete", ["virtualMachineId": .string(providerRef)])
    }

    func waitForServer(_ id: String) async throws -> JSONValue {
        let client = self.client
        return try await client.waitUntilActive("Server \(id)") {
            try await client.findPage("machine", "virtualMachinesFind", filter: .equal("VirtualMachineId", id), limit: 1).data.first
        }
    }
}

extension HostingDeAdapter: SubaccountAdapter {
    func subaccount(_ item: JSONValue) -> Subaccount {
        let login = item.string("accountName") ?? item.string("name") ?? item.string("id") ?? ""
        var extra: Extra = [:]
        for (key, value) in item.objectValue ?? [:] where value != .null { extra[key] = value }
        return Subaccount(ref: ref(item.string("id") ?? login), login: login, comment: item.string("description") ?? item.string("comments"), extra: extra)
    }

    public func listSubaccounts() async throws -> [Subaccount] {
        try await client.findAll("account", "subaccountsFind").map { subaccount($0) }.sorted { $0.login < $1.login }
    }

    public func createSubaccount(password: String, comment: String?, extra: Extra) async throws -> Subaccount {
        throw KastellanError.unsupported("hosting.de: Unterkonten werden nicht über Kastellan angelegt (account-Dienst nicht dokumentiert)")
    }

    public func deleteSubaccount(login: String) async throws {
        throw KastellanError.unsupported("hosting.de: Unterkonten werden nicht über Kastellan gelöscht")
    }
}

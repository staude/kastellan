import Foundation

/// Beschreibung eines Parameters für Tool-Schemas und UI.
public struct ParameterSpec: Sendable, Equatable {
    public enum Kind: String, Sendable { case string, integer, boolean, stringArray = "string_array", object }

    public let name: String
    public let kind: Kind
    public let required: Bool
    public let description: String

    public init(_ name: String, kind: Kind = .string, required: Bool = true, _ description: String) {
        self.name = name; self.kind = kind; self.required = required; self.description = description
    }
}

/// Eingaben eines Aufrufs mit typisierten Zugriffen.
public struct ActionInput: Sendable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue]) { self.values = values }

    public func string(_ key: String) throws -> String {
        guard let v = values[key]?.stringValue, !v.isEmpty else { throw KastellanError.invalidArgument("\(key) fehlt") }
        return v
    }

    public func optionalString(_ key: String) -> String? {
        values[key].flatMap { $0 == .null ? nil : $0.stringValue }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func optionalInt(_ key: String) -> Int? {
        switch values[key] {
        case .int(let i): i
        case .double(let d): Int(d)
        case .string(let s): Int(s)
        default: nil
        }
    }

    public func optionalBool(_ key: String) -> Bool? {
        switch values[key] {
        case .bool(let b): b
        case .string(let s): ["true", "yes", "y", "1"].contains(s.lowercased()) ? true : (["false", "no", "n", "0"].contains(s.lowercased()) ? false : nil)
        default: nil
        }
    }

    public func stringArray(_ key: String) -> [String]? {
        switch values[key] {
        case .array(let a): a.compactMap(\.stringValue)
        case .string(let s): s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: nil
        }
    }

    public func extra(_ key: String = "extra") -> Extra {
        if case .object(let o) = values[key] ?? .null { return o }
        return [:]
    }
}

/// Was aus den Eingaben wird: Ziel, Record-Typ, Vorschau und die eigentliche Operation.
public struct PreparedAction: Sendable {
    public var target: String?
    public var recordType: String?
    public var preview: String
    /// Aus den Eingaben ergibt sich Bestätigungspflicht (etwa Server ausschalten), unabhängig von der Policy.
    public var requiresConfirmation: Bool
    public var operation: ActionExecutor.Operation

    public init(target: String?, recordType: String? = nil, preview: String, requiresConfirmation: Bool = false,
                operation: @escaping ActionExecutor.Operation) {
        self.target = target; self.recordType = recordType; self.preview = preview
        self.requiresConfirmation = requiresConfirmation; self.operation = operation
    }
}

/// Zusatzinformationen beim Bauen einer Operation (Ablage für generierte Passwörter, Policy-Flags).
public struct ActionContext: Sendable {
    public let connectionID: String
    public let connectionLabel: String
    public let profileID: String
    public let secrets: any SecretStore
    public let revealGeneratedPasswords: Bool
    public let deliverer: CredentialDeliverer?

    public init(connectionID: String, connectionLabel: String = "", profileID: String = "", secrets: any SecretStore,
                revealGeneratedPasswords: Bool, deliverer: CredentialDeliverer? = nil) {
        self.connectionID = connectionID; self.connectionLabel = connectionLabel; self.profileID = profileID
        self.secrets = secrets; self.revealGeneratedPasswords = revealGeneratedPasswords; self.deliverer = deliverer
    }
}

/// Eine benannte Aktion, aus der MCP-Tools, Vorschauen und die Wiederholung bei Freigabe entstehen.
public struct ActionSpec: Sendable {
    public let name: String
    public let capability: Capability
    public let descriptionDE: String
    public let descriptionEN: String
    public let parameters: [ParameterSpec]
    /// Aktion legt immer eine Pending Action an (Name enthält `prepare_`).
    public let prepares: Bool
    public let build: @Sendable (ActionInput, ActionContext) throws -> PreparedAction

    public var isReadOnly: Bool { capability.action == .list || capability.action == .get }
    public var isDestructive: Bool { capability.action == .delete }
    public var isIdempotent: Bool { capability.action != .create }
    public var description: String { "\(descriptionDE) / \(descriptionEN)" }

    public init(_ name: String, _ capability: Capability, de: String, en: String, parameters: [ParameterSpec] = [],
                prepares: Bool = false, build: @escaping @Sendable (ActionInput, ActionContext) throws -> PreparedAction) {
        self.name = name; self.capability = capability; self.descriptionDE = de; self.descriptionEN = en
        self.parameters = parameters; self.prepares = prepares; self.build = build
    }
}

enum ActionErrors {
    static func needs<T>(_ adapter: any ProviderAdapter, _ type: T.Type, _ what: String) throws -> T {
        guard let a = adapter as? T else { throw KastellanError.unsupported("\(what) kann dieser Provider nicht") }
        return a
    }
}

extension JSONValue {
    /// Kodiert ein Modell als JSONValue für Tool-Ergebnisse.
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONCoding.decoder.decode(JSONValue.self, from: JSONCoding.encoder.encode(value))
    }
}

/// Legt ein generiertes Passwort als vollständigen Zugang ab (Schlüsselbund, Bitwarden, 1Password oder nur im Ergebnis)
/// und ergänzt das Ergebnis um `password` und `password_storage`.
private func storeGenerated(_ ctx: ActionContext, _ resource: ResourceType, _ identifier: String, _ password: String,
                            into result: inout JSONValue, username: String? = nil, adapter: (any ProviderAdapter)? = nil) async throws {
    let service = adapter?.credentialService(for: resource)
    let record = CredentialRecord(
        title: CredentialRecord.title(for: resource, identifier: identifier, connectionLabel: ctx.connectionLabel),
        username: username ?? identifier, password: password, host: service?.host, scheme: service?.scheme ?? "https", port: service?.port,
        resource: resource, identifier: identifier, connectionID: ctx.connectionID, connectionLabel: ctx.connectionLabel, profileID: ctx.profileID)
    let outcome: CredentialDeliveryOutcome
    if let deliverer = ctx.deliverer {
        outcome = await deliverer.deliver(record)
    } else {
        // Ohne Ablage-Schicht (Tests, alte Aufrufer): wie bisher als generisches Schlüsselbund-Item.
        try await ctx.secrets.set(connectionID: ctx.connectionID, key: PasswordGenerator.secretKey(resource, identifier), value: password)
        outcome = .stored("Schlüsselbund, \(PasswordGenerator.secretKey(resource, identifier))")
    }
    if case .object(var o) = result {
        for (k, v) in CredentialDeliverer.resultFields(outcome: outcome, password: password, reveal: ctx.revealGeneratedPasswords) { o[k] = v }
        result = .object(o)
    }
}

/// Alle Aktionen. Reihenfolge = Reihenfolge der MCP-Tools.
public enum ActionCatalog {
    public static let connectionParam = ParameterSpec("connection_id", required: false, "Verbindung (siehe kastellan_list_connections). Fehlt sie, wird sie über die Domain-Zuordnung ermittelt. / Connection id, resolved from the domain assignment when omitted.")

    public static func spec(named name: String) -> ActionSpec? { all.first { $0.name == name } }
    public static func spec(for capability: Capability) -> ActionSpec? { all.first { $0.capability == capability } }

    public static let all: [ActionSpec] = domain + subdomain + dns + dkim + mailbox + mailForward + autoresponder
        + mailingList + ftp + ssh + database + cron + certificate + directoryProtection + subaccount + server + firewall

    // MARK: SSH-Keys

    static let ssh: [ActionSpec] = [
        ActionSpec("ssh_user_list", Capability(.sshUser, .list), de: "SSH-Zugänge oder SSH-Keys auflisten", en: "List SSH users or SSH keys",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "SSH-Keys auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any SSHUserAdapter).self, "ssh_user").listSSHUsers())
            }
        },
        ActionSpec("ssh_user_create", Capability(.sshUser, .create), de: "SSH-Key hinterlegen", en: "Add an SSH key",
                   parameters: [connectionParam, ParameterSpec("public_keys", kind: .stringArray, "Öffentliche Schlüssel"),
                                ParameterSpec("username", required: false, "Name oder Login, falls der Provider das erlaubt")]) { input, _ in
            let keys = input.stringArray("public_keys") ?? []
            guard !keys.isEmpty else { throw KastellanError.invalidArgument("public_keys fehlt") }
            let username = input.optionalString("username")
            return PreparedAction(target: username, preview: "SSH-Key \(username ?? "") hinterlegen") { a in
                try .encode(try await ActionErrors.needs(a, (any SSHUserAdapter).self, "ssh_user").createSSHUser(username: username, publicKeys: keys))
            }
        },
        ActionSpec("ssh_user_prepare_delete", Capability(.sshUser, .delete), de: "SSH-Key oder SSH-Zugang entfernen (Freigabe nötig)", en: "Remove an SSH key or user (requires approval)",
                   parameters: [connectionParam, ParameterSpec("username", "Name oder Login")], prepares: true) { input, _ in
            let username = try input.string("username")
            return PreparedAction(target: username, preview: "SSH-Key \(username) entfernen") { a in
                try await ActionErrors.needs(a, (any SSHUserAdapter).self, "ssh_user").deleteSSHUser(username: username)
                return .object(["deleted": .string(username)])
            }
        },
    ]

    // MARK: Server

    static let server: [ActionSpec] = [
        ActionSpec("server_list", Capability(.server, .list), de: "Server auflisten (Name, Status, IPs, Typ, Standort)", en: "List servers (name, status, IPs, type, location)",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "Server auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any ServerAdapter).self, "server").listServers())
            }
        },
        ActionSpec("server_get", Capability(.server, .get), de: "Einen Server lesen", en: "Get one server",
                   parameters: [connectionParam, ParameterSpec("provider_ref", "Server-Kennung aus server_list")]) { input, _ in
            let ref = try input.string("provider_ref")
            return PreparedAction(target: ref, preview: "Server \(ref) lesen") { a in
                try .encode(try await ActionErrors.needs(a, (any ServerAdapter).self, "server").getServer(providerRef: ref))
            }
        },
        ActionSpec("server_prepare_create", Capability(.server, .create), de: "Server anlegen (Freigabe nötig, kostet Geld)", en: "Create a server (requires approval, incurs cost)",
                   parameters: [connectionParam, ParameterSpec("name", "Name"), ParameterSpec("type", "Servertyp, z. B. cx22"), ParameterSpec("image", "Image, z. B. ubuntu-24.04"),
                                ParameterSpec("location", required: false, "Standort, z. B. fsn1"), ParameterSpec("ssh_keys", kind: .stringArray, required: false, "Namen hinterlegter SSH-Keys"),
                                ParameterSpec("labels", kind: .object, required: false, "Labels")], prepares: true) { input, ctx in
            let name = try input.string("name"); let type = try input.string("type"); let image = try input.string("image")
            var labels: [String: String] = [:]
            for (k, v) in input.extra("labels") { if let s = v.stringValue { labels[k] = s } }
            let spec = ServerSpec(name: name, type: type, image: image, location: input.optionalString("location"), sshKeys: input.stringArray("ssh_keys") ?? [], labels: labels)
            return PreparedAction(target: name, preview: "Server \(name) (\(type), \(image)\(spec.location.map { ", \($0)" } ?? "")) anlegen") { a in
                var server = try await ActionErrors.needs(a, (any ServerAdapter).self, "server").createServer(spec)
                // Root-Passwort (nur ohne SSH-Key) gehört in den Schlüsselbund, nicht ins Tool-Ergebnis.
                if let rootPassword = server.extra["root_password"]?.stringValue {
                    server.extra.removeValue(forKey: "root_password")
                    var result = try JSONValue.encode(server)
                    try await storeGenerated(ctx, .server, server.name, rootPassword, into: &result, username: "root", adapter: a)
                    if case .object(var o) = result { o["root_password"] = o.removeValue(forKey: "password"); result = .object(o) }
                    return result
                }
                return try .encode(server)
            }
        },
        ActionSpec("server_update", Capability(.server, .update), de: "Server umbenennen, Labels setzen oder Power-Aktion (power_on direkt; power_off, reboot, shutdown mit Freigabe)", en: "Rename, set labels or run a power action (power_on directly; power_off, reboot, shutdown require approval)",
                   parameters: [connectionParam, ParameterSpec("provider_ref", "Server-Kennung"), ParameterSpec("name", required: false, "Neuer Name"),
                                ParameterSpec("labels", kind: .object, required: false, "Labels (ersetzen)"), ParameterSpec("power", required: false, "power_on, power_off, reboot, shutdown")]) { input, _ in
            let ref = try input.string("provider_ref")
            let name = input.optionalString("name")
            var labels: [String: String]? = nil
            if case .object(let o) = input.values["labels"] ?? .null { labels = o.compactMapValues(\.stringValue) }
            var power: ServerPowerAction? = nil
            if let p = input.optionalString("power") {
                guard let parsed = ServerPowerAction(rawValue: p) else { throw KastellanError.invalidArgument("power muss power_on, power_off, reboot oder shutdown sein") }
                power = parsed
            }
            guard name != nil || labels != nil || power != nil else { throw KastellanError.invalidArgument("name, labels oder power angeben") }
            let what = [name.map { "umbenennen in \($0)" }, labels.map { _ in "Labels setzen" }, power.map { $0.rawValue }].compactMap { $0 }.joined(separator: ", ")
            let finalLabels = labels
            let finalPower = power
            return PreparedAction(target: ref, preview: "Server \(ref): \(what)", requiresConfirmation: finalPower?.isDisruptive ?? false) { a in
                try .encode(try await ActionErrors.needs(a, (any ServerAdapter).self, "server").updateServer(providerRef: ref, name: name, labels: finalLabels, power: finalPower))
            }
        },
        ActionSpec("server_prepare_delete", Capability(.server, .delete), de: "Server löschen (Freigabe nötig, unwiderruflich)", en: "Delete a server (requires approval, irreversible)",
                   parameters: [connectionParam, ParameterSpec("provider_ref", "Server-Kennung")], prepares: true) { input, _ in
            let ref = try input.string("provider_ref")
            return PreparedAction(target: ref, preview: "Server \(ref) unwiderruflich löschen") { a in
                try await ActionErrors.needs(a, (any ServerAdapter).self, "server").deleteServer(providerRef: ref)
                return .object(["deleted": .string(ref)])
            }
        },
    ]

    // MARK: Firewall

    static let firewall: [ActionSpec] = [
        ActionSpec("firewall_list", Capability(.firewall, .list), de: "Firewalls mit Regeln auflisten", en: "List firewalls with rules",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "Firewalls auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any FirewallAdapter).self, "firewall").listFirewalls())
            }
        },
        ActionSpec("firewall_get", Capability(.firewall, .get), de: "Eine Firewall lesen", en: "Get one firewall",
                   parameters: [connectionParam, ParameterSpec("provider_ref", "Firewall-Kennung")]) { input, _ in
            let ref = try input.string("provider_ref")
            return PreparedAction(target: ref, preview: "Firewall \(ref) lesen") { a in
                try .encode(try await ActionErrors.needs(a, (any FirewallAdapter).self, "firewall").getFirewall(providerRef: ref))
            }
        },
    ]

    // MARK: Domain

    static let domain: [ActionSpec] = [
        ActionSpec("domain_list", Capability(.domain, .list), de: "Domains einer Verbindung auflisten", en: "List domains of a connection",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "Domains auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any DomainAdapter).self, "domain").listDomains())
            }
        },
        ActionSpec("domain_get", Capability(.domain, .get), de: "Eine Domain lesen", en: "Get one domain",
                   parameters: [connectionParam, ParameterSpec("fqdn", "Domainname / domain name")]) { input, _ in
            let fqdn = try input.string("fqdn")
            return PreparedAction(target: fqdn, preview: "Domain \(fqdn) lesen") { a in
                try .encode(try await ActionErrors.needs(a, (any DomainAdapter).self, "domain").getDomain(fqdn: fqdn))
            }
        },
        ActionSpec("domain_create", Capability(.domain, .create), de: "Domain im Hosting anlegen (keine Registrierung)", en: "Add a domain to the hosting account (no registration)",
                   parameters: [connectionParam, ParameterSpec("fqdn", "Domainname"), ParameterSpec("path", required: false, "Webspace-Pfad / document root"),
                                ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches")]) { input, _ in
            let fqdn = try input.string("fqdn"); let path = input.optionalString("path"); let extra = input.extra()
            return PreparedAction(target: fqdn, preview: "Domain \(fqdn) anlegen\(path.map { ", Pfad \($0)" } ?? "")") { a in
                try .encode(try await ActionErrors.needs(a, (any DomainAdapter).self, "domain").createDomain(fqdn: fqdn, path: path, extra: extra))
            }
        },
        ActionSpec("domain_update", Capability(.domain, .update), de: "Domain-Einstellungen ändern. Nameserver-Wechsel (extra.nameservers) braucht eine Freigabe.", en: "Update domain settings. Changing nameservers (extra.nameservers) requires approval.",
                   parameters: [connectionParam, ParameterSpec("fqdn", "Domainname"), ParameterSpec("path", required: false, "Webspace-Pfad"),
                                ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches")]) { input, _ in
            let fqdn = try input.string("fqdn"); let path = input.optionalString("path"); let extra = input.extra()
            // Nameserver-Wechsel ist eine NS-Änderung und läuft wie MX/NS/SOA immer über eine Freigabe.
            let nameservers = extra["nameservers"]
            let preview = nameservers.map { "Nameserver von \(fqdn) ändern auf \($0.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? $0.stringValue ?? "?")" }
                ?? "Domain \(fqdn) ändern"
            return PreparedAction(target: fqdn, preview: preview, requiresConfirmation: nameservers != nil) { a in
                try .encode(try await ActionErrors.needs(a, (any DomainAdapter).self, "domain").updateDomain(fqdn: fqdn, path: path, extra: extra))
            }
        },
        ActionSpec("domain_prepare_delete", Capability(.domain, .delete), de: "Domain aus dem Hosting entfernen (Freigabe nötig)", en: "Remove a domain from hosting (requires approval)",
                   parameters: [connectionParam, ParameterSpec("fqdn", "Domainname")], prepares: true) { input, _ in
            let fqdn = try input.string("fqdn")
            return PreparedAction(target: fqdn, preview: "Domain \(fqdn) aus dem Hosting entfernen") { a in
                try await ActionErrors.needs(a, (any DomainAdapter).self, "domain").deleteDomain(fqdn: fqdn)
                return .object(["deleted": .string(fqdn)])
            }
        },
    ]

    // MARK: Subdomain

    static let subdomain: [ActionSpec] = [
        ActionSpec("subdomain_list", Capability(.subdomain, .list), de: "Subdomains auflisten", en: "List subdomains",
                   parameters: [connectionParam, ParameterSpec("parent", required: false, "Nur Subdomains dieser Domain")]) { input, _ in
            let parent = input.optionalString("parent")
            return PreparedAction(target: parent, preview: "Subdomains auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any SubdomainAdapter).self, "subdomain").listSubdomains(parent: parent))
            }
        },
        ActionSpec("subdomain_create", Capability(.subdomain, .create), de: "Subdomain anlegen", en: "Create a subdomain",
                   parameters: [connectionParam, ParameterSpec("fqdn", "Vollständiger Name, z. B. planer.example.de"),
                                ParameterSpec("target_path", required: false, "Webspace-Pfad"), ParameterSpec("redirect", required: false, "Weiterleitungs-URL"),
                                ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches")]) { input, _ in
            let fqdn = try input.string("fqdn"); let path = input.optionalString("target_path"); let redirect = input.optionalString("redirect"); let extra = input.extra()
            return PreparedAction(target: fqdn, preview: "Subdomain \(fqdn) anlegen") { a in
                try .encode(try await ActionErrors.needs(a, (any SubdomainAdapter).self, "subdomain").createSubdomain(fqdn: fqdn, targetPath: path, redirect: redirect, extra: extra))
            }
        },
        ActionSpec("subdomain_update", Capability(.subdomain, .update), de: "Subdomain ändern", en: "Update a subdomain",
                   parameters: [connectionParam, ParameterSpec("fqdn", "Vollständiger Name"), ParameterSpec("target_path", required: false, "Webspace-Pfad"),
                                ParameterSpec("redirect", required: false, "Weiterleitungs-URL"), ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches")]) { input, _ in
            let fqdn = try input.string("fqdn"); let path = input.optionalString("target_path"); let redirect = input.optionalString("redirect"); let extra = input.extra()
            return PreparedAction(target: fqdn, preview: "Subdomain \(fqdn) ändern") { a in
                try .encode(try await ActionErrors.needs(a, (any SubdomainAdapter).self, "subdomain").updateSubdomain(fqdn: fqdn, targetPath: path, redirect: redirect, extra: extra))
            }
        },
        ActionSpec("subdomain_prepare_delete", Capability(.subdomain, .delete), de: "Subdomain löschen (Freigabe nötig)", en: "Delete a subdomain (requires approval)",
                   parameters: [connectionParam, ParameterSpec("fqdn", "Vollständiger Name")], prepares: true) { input, _ in
            let fqdn = try input.string("fqdn")
            return PreparedAction(target: fqdn, preview: "Subdomain \(fqdn) löschen") { a in
                try await ActionErrors.needs(a, (any SubdomainAdapter).self, "subdomain").deleteSubdomain(fqdn: fqdn)
                return .object(["deleted": .string(fqdn)])
            }
        },
    ]

    // MARK: DNS

    static let dns: [ActionSpec] = [
        ActionSpec("dns_zone_list", Capability(.dnsZone, .list), de: "DNS-Zonen auflisten", en: "List DNS zones",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "Zonen auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any DNSAdapter).self, "dns").listZones())
            }
        },
        ActionSpec("dns_record_list", Capability(.dnsRecord, .list), de: "DNS-Records einer Zone auflisten", en: "List DNS records of a zone",
                   parameters: [connectionParam, ParameterSpec("zone", "Zone, z. B. example.de")]) { input, _ in
            let zone = try input.string("zone")
            return PreparedAction(target: zone, preview: "Records von \(zone) auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any DNSAdapter).self, "dns").listRecords(zone: zone))
            }
        },
        ActionSpec("dns_record_create", Capability(.dnsRecord, .create), de: "DNS-Record anlegen. MX, NS und SOA brauchen Stufe manage und Freigabe.", en: "Create a DNS record. MX, NS and SOA need level manage and approval.",
                   parameters: [connectionParam, ParameterSpec("zone", "Zone"), ParameterSpec("name", "Name relativ zur Zone, @ für die Zone selbst"),
                                ParameterSpec("type", "A, AAAA, CNAME, TXT, MX, ..."), ParameterSpec("content", "Inhalt"),
                                ParameterSpec("ttl", kind: .integer, required: false, "TTL in Sekunden"), ParameterSpec("priority", kind: .integer, required: false, "Priorität (MX, SRV)")]) { input, _ in
            let zone = try input.string("zone"); let name = try input.string("name"); let type = try input.string("type").uppercased()
            let content = try input.string("content"); let ttl = input.optionalInt("ttl"); let prio = input.optionalInt("priority")
            return PreparedAction(target: zone, recordType: type, preview: "\(type)-Record \(name).\(zone) = \(content) anlegen") { a in
                try .encode(try await ActionErrors.needs(a, (any DNSAdapter).self, "dns").createRecord(zone: zone, name: name, type: type, content: content, ttl: ttl, priority: prio))
            }
        },
        ActionSpec("dns_record_update", Capability(.dnsRecord, .update), de: "DNS-Record ändern (provider_ref aus dns_record_list)", en: "Update a DNS record (provider_ref from dns_record_list)",
                   parameters: [connectionParam, ParameterSpec("zone", "Zone"), ParameterSpec("provider_ref", "Record-Kennung"), ParameterSpec("type", "Record-Typ (für die Rechteprüfung)"),
                                ParameterSpec("content", required: false, "Neuer Inhalt"), ParameterSpec("ttl", kind: .integer, required: false, "TTL"), ParameterSpec("priority", kind: .integer, required: false, "Priorität")]) { input, _ in
            let zone = try input.string("zone"); let ref = try input.string("provider_ref"); let type = try input.string("type").uppercased()
            let content = input.optionalString("content"); let ttl = input.optionalInt("ttl"); let prio = input.optionalInt("priority")
            return PreparedAction(target: zone, recordType: type, preview: "\(type)-Record \(ref) in \(zone) ändern\(content.map { " auf \($0)" } ?? "")") { a in
                try .encode(try await ActionErrors.needs(a, (any DNSAdapter).self, "dns").updateRecord(zone: zone, providerRef: ref, content: content, ttl: ttl, priority: prio))
            }
        },
        ActionSpec("dns_record_prepare_delete", Capability(.dnsRecord, .delete), de: "DNS-Record löschen (Freigabe nötig)", en: "Delete a DNS record (requires approval)",
                   parameters: [connectionParam, ParameterSpec("zone", "Zone"), ParameterSpec("provider_ref", "Record-Kennung"), ParameterSpec("type", "Record-Typ")], prepares: true) { input, _ in
            let zone = try input.string("zone"); let ref = try input.string("provider_ref"); let type = try input.string("type").uppercased()
            return PreparedAction(target: zone, recordType: type, preview: "\(type)-Record \(ref) in \(zone) löschen") { a in
                try await ActionErrors.needs(a, (any DNSAdapter).self, "dns").deleteRecord(zone: zone, providerRef: ref)
                return .object(["deleted": .string(ref)])
            }
        },
    ]

    // MARK: DKIM

    static let dkim: [ActionSpec] = [
        ActionSpec("dkim_get", Capability(.dkim, .get), de: "DKIM-Schlüssel einer Domain lesen (Selector, Public Key, fertiger TXT-Record)", en: "Read the DKIM key of a domain (selector, public key, TXT record)",
                   parameters: [connectionParam, ParameterSpec("domain", "Domain")]) { input, _ in
            let domain = try input.string("domain")
            return PreparedAction(target: domain, preview: "DKIM von \(domain) lesen") { a in
                guard let key = try await ActionErrors.needs(a, (any DKIMAdapter).self, "dkim").getDKIM(domain: domain) else { return .null }
                var v = try JSONValue.encode(key)
                if case .object(var o) = v {
                    o["txt_record_name"] = .string(key.recordName)
                    o["txt_record_content"] = .string(key.txtRecord)
                    v = .object(o)
                }
                return v
            }
        },
        ActionSpec("dkim_prepare_create", Capability(.dkim, .create), de: "DKIM für eine Domain aktivieren (Freigabe nötig, danach TXT-Record setzen)", en: "Enable DKIM for a domain (requires approval, then publish the TXT record)",
                   parameters: [connectionParam, ParameterSpec("domain", "Domain")], prepares: true) { input, _ in
            let domain = try input.string("domain")
            return PreparedAction(target: domain, preview: "DKIM für \(domain) aktivieren") { a in
                try .encode(try await ActionErrors.needs(a, (any DKIMAdapter).self, "dkim").createDKIM(domain: domain))
            }
        },
        ActionSpec("dkim_prepare_delete", Capability(.dkim, .delete), de: "DKIM einer Domain entfernen (Freigabe nötig)", en: "Remove DKIM from a domain (requires approval)",
                   parameters: [connectionParam, ParameterSpec("domain", "Domain")], prepares: true) { input, _ in
            let domain = try input.string("domain")
            return PreparedAction(target: domain, preview: "DKIM für \(domain) entfernen") { a in
                try await ActionErrors.needs(a, (any DKIMAdapter).self, "dkim").deleteDKIM(domain: domain)
                return .object(["deleted": .string(domain)])
            }
        },
    ]

    // MARK: Mailbox

    static let mailbox: [ActionSpec] = [
        ActionSpec("mailbox_list", Capability(.mailbox, .list), de: "Postfächer auflisten", en: "List mailboxes",
                   parameters: [connectionParam, ParameterSpec("domain", required: false, "Nur Postfächer dieser Domain")]) { input, _ in
            let domain = input.optionalString("domain")
            return PreparedAction(target: domain, preview: "Postfächer auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any MailboxAdapter).self, "mailbox").listMailboxes(domain: domain))
            }
        },
        ActionSpec("mailbox_get", Capability(.mailbox, .get), de: "Ein Postfach lesen", en: "Get one mailbox",
                   parameters: [connectionParam, ParameterSpec("address", "E-Mail-Adresse")]) { input, _ in
            let address = try input.string("address")
            return PreparedAction(target: address, preview: "Postfach \(address) lesen") { a in
                try .encode(try await ActionErrors.needs(a, (any MailboxAdapter).self, "mailbox").getMailbox(address: address))
            }
        },
        ActionSpec("mailbox_create", Capability(.mailbox, .create), de: "Postfach anlegen. Ohne Passwort erzeugt Kastellan eines und legt es im Schlüsselbund ab.", en: "Create a mailbox. Without a password Kastellan generates one and stores it in the keychain.",
                   parameters: [connectionParam, ParameterSpec("address", "E-Mail-Adresse"), ParameterSpec("password", required: false, "Passwort (optional)"),
                                ParameterSpec("quota_mb", kind: .integer, required: false, "Speicher in MB"), ParameterSpec("copy_to", kind: .stringArray, required: false, "Kopie an diese Adressen"),
                                ParameterSpec("sender_aliases", kind: .stringArray, required: false, "Erlaubte Absender-Aliase"), ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches")]) { input, ctx in
            let address = try input.string("address")
            let given = input.optionalString("password")
            let password = given ?? PasswordGenerator.generate()
            let spec = MailboxSpec(address: address, password: password, quotaMB: input.optionalInt("quota_mb"), copyTo: input.stringArray("copy_to"),
                                   senderAliases: input.stringArray("sender_aliases"), extra: input.extra())
            return PreparedAction(target: address, preview: "Postfach \(address) anlegen\(given == nil ? " (Passwort wird erzeugt)" : "")") { a in
                let box = try await ActionErrors.needs(a, (any MailboxAdapter).self, "mailbox").createMailbox(spec)
                var result = try JSONValue.encode(box)
                if given == nil { try await storeGenerated(ctx, .mailbox, address, password, into: &result, username: address, adapter: a) }
                return result
            }
        },
        ActionSpec("mailbox_update", Capability(.mailbox, .update), de: "Postfach ändern (Quota, Kopie, Absender-Aliase)", en: "Update a mailbox (quota, copy, sender aliases)",
                   parameters: [connectionParam, ParameterSpec("address", "E-Mail-Adresse"), ParameterSpec("quota_mb", kind: .integer, required: false, "Speicher in MB"),
                                ParameterSpec("copy_to", kind: .stringArray, required: false, "Kopie an"), ParameterSpec("sender_aliases", kind: .stringArray, required: false, "Absender-Aliase"),
                                ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches")]) { input, _ in
            let address = try input.string("address")
            let spec = MailboxSpec(address: address, quotaMB: input.optionalInt("quota_mb"), copyTo: input.stringArray("copy_to"),
                                   senderAliases: input.stringArray("sender_aliases"), extra: input.extra())
            return PreparedAction(target: address, preview: "Postfach \(address) ändern") { a in
                try .encode(try await ActionErrors.needs(a, (any MailboxAdapter).self, "mailbox").updateMailbox(spec))
            }
        },
        ActionSpec("mailbox_set_password", Capability(.mailbox, .setPassword), de: "Postfach-Passwort setzen. Ohne Angabe wird eines erzeugt und im Schlüsselbund abgelegt.", en: "Set a mailbox password. Without a value one is generated and stored in the keychain.",
                   parameters: [connectionParam, ParameterSpec("address", "E-Mail-Adresse"), ParameterSpec("password", required: false, "Neues Passwort (optional)")]) { input, ctx in
            let address = try input.string("address")
            let given = input.optionalString("password")
            let password = given ?? PasswordGenerator.generate()
            return PreparedAction(target: address, preview: "Passwort von \(address) setzen") { a in
                try await ActionErrors.needs(a, (any MailboxAdapter).self, "mailbox").setMailboxPassword(address: address, password: password)
                var result: JSONValue = .object(["address": .string(address), "password": .string("gesetzt")])
                if given == nil { try await storeGenerated(ctx, .mailbox, address, password, into: &result, username: address, adapter: a) }
                return result
            }
        },
        ActionSpec("mailbox_prepare_delete", Capability(.mailbox, .delete), de: "Postfach löschen (Freigabe nötig)", en: "Delete a mailbox (requires approval)",
                   parameters: [connectionParam, ParameterSpec("address", "E-Mail-Adresse")], prepares: true) { input, ctx in
            let address = try input.string("address")
            return PreparedAction(target: address, preview: "Postfach \(address) mit allen Mails löschen") { a in
                try await ActionErrors.needs(a, (any MailboxAdapter).self, "mailbox").deleteMailbox(address: address)
                try? await ctx.secrets.delete(connectionID: ctx.connectionID, key: PasswordGenerator.secretKey(.mailbox, address))
                return .object(["deleted": .string(address)])
            }
        },
    ]

    // MARK: Mail forward

    static let mailForward: [ActionSpec] = [
        ActionSpec("mail_forward_list", Capability(.mailForward, .list), de: "Weiterleitungen auflisten", en: "List mail forwards",
                   parameters: [connectionParam, ParameterSpec("domain", required: false, "Nur diese Domain")]) { input, _ in
            let domain = input.optionalString("domain")
            return PreparedAction(target: domain, preview: "Weiterleitungen auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any MailForwardAdapter).self, "mail_forward").listForwards(domain: domain))
            }
        },
        ActionSpec("mail_forward_create", Capability(.mailForward, .create), de: "Weiterleitung anlegen", en: "Create a mail forward",
                   parameters: [connectionParam, ParameterSpec("address", "Quelladresse"), ParameterSpec("targets", kind: .stringArray, "Zieladressen"),
                                ParameterSpec("keep_copy", kind: .boolean, required: false, "Kopie behalten, falls der Provider das kann")]) { input, _ in
            let address = try input.string("address"); let targets = input.stringArray("targets") ?? []; let keep = input.optionalBool("keep_copy") ?? false
            guard !targets.isEmpty else { throw KastellanError.invalidArgument("targets fehlt") }
            return PreparedAction(target: address, preview: "Weiterleitung \(address) → \(targets.joined(separator: ", ")) anlegen") { a in
                try .encode(try await ActionErrors.needs(a, (any MailForwardAdapter).self, "mail_forward").createForward(address: address, targets: targets, keepCopy: keep))
            }
        },
        ActionSpec("mail_forward_update", Capability(.mailForward, .update), de: "Ziele einer Weiterleitung ändern", en: "Update targets of a mail forward",
                   parameters: [connectionParam, ParameterSpec("address", "Quelladresse"), ParameterSpec("targets", kind: .stringArray, "Zieladressen"),
                                ParameterSpec("keep_copy", kind: .boolean, required: false, "Kopie behalten")]) { input, _ in
            let address = try input.string("address"); let targets = input.stringArray("targets") ?? []; let keep = input.optionalBool("keep_copy") ?? false
            guard !targets.isEmpty else { throw KastellanError.invalidArgument("targets fehlt") }
            return PreparedAction(target: address, preview: "Weiterleitung \(address) → \(targets.joined(separator: ", ")) ändern") { a in
                try .encode(try await ActionErrors.needs(a, (any MailForwardAdapter).self, "mail_forward").updateForward(address: address, targets: targets, keepCopy: keep))
            }
        },
        ActionSpec("mail_forward_prepare_delete", Capability(.mailForward, .delete), de: "Weiterleitung löschen (Freigabe nötig)", en: "Delete a mail forward (requires approval)",
                   parameters: [connectionParam, ParameterSpec("address", "Quelladresse")], prepares: true) { input, _ in
            let address = try input.string("address")
            return PreparedAction(target: address, preview: "Weiterleitung \(address) löschen") { a in
                try await ActionErrors.needs(a, (any MailForwardAdapter).self, "mail_forward").deleteForward(address: address)
                return .object(["deleted": .string(address)])
            }
        },
    ]

    // MARK: Autoresponder

    static let autoresponder: [ActionSpec] = [
        ActionSpec("mail_autoresponder_get", Capability(.mailAutoresponder, .get), de: "Autoresponder eines Postfachs lesen", en: "Read a mailbox autoresponder",
                   parameters: [connectionParam, ParameterSpec("address", "E-Mail-Adresse")]) { input, _ in
            let address = try input.string("address")
            return PreparedAction(target: address, preview: "Autoresponder \(address) lesen") { a in
                try .encode(try await ActionErrors.needs(a, (any MailAutoresponderAdapter).self, "mail_autoresponder").getAutoresponder(address: address))
            }
        },
        ActionSpec("mail_autoresponder_set", Capability(.mailAutoresponder, .update), de: "Autoresponder setzen oder ändern", en: "Set or update an autoresponder",
                   parameters: [connectionParam, ParameterSpec("address", "E-Mail-Adresse"), ParameterSpec("text", "Antworttext"),
                                ParameterSpec("subject", required: false, "Betreff"), ParameterSpec("active", kind: .boolean, required: false, "Aktiv (Standard ja)")]) { input, _ in
            let address = try input.string("address"); let text = try input.string("text")
            let responder = MailAutoresponder(ref: ResourceRef(connectionID: "", providerRef: ""), address: address,
                                              active: input.optionalBool("active") ?? true, subject: input.optionalString("subject"), text: text)
            return PreparedAction(target: address, preview: "Autoresponder für \(address) setzen") { a in
                try .encode(try await ActionErrors.needs(a, (any MailAutoresponderAdapter).self, "mail_autoresponder").setAutoresponder(responder))
            }
        },
        ActionSpec("mail_autoresponder_clear", Capability(.mailAutoresponder, .delete), de: "Autoresponder abschalten", en: "Disable an autoresponder",
                   parameters: [connectionParam, ParameterSpec("address", "E-Mail-Adresse")]) { input, _ in
            let address = try input.string("address")
            return PreparedAction(target: address, preview: "Autoresponder für \(address) abschalten") { a in
                try await ActionErrors.needs(a, (any MailAutoresponderAdapter).self, "mail_autoresponder").clearAutoresponder(address: address)
                return .object(["cleared": .string(address)])
            }
        },
    ]

    // MARK: Mailing list

    static let mailingList: [ActionSpec] = [
        ActionSpec("mailing_list_list", Capability(.mailingList, .list), de: "Mailinglisten auflisten", en: "List mailing lists",
                   parameters: [connectionParam, ParameterSpec("domain", required: false, "Nur diese Domain")]) { input, _ in
            let domain = input.optionalString("domain")
            return PreparedAction(target: domain, preview: "Mailinglisten auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any MailingListAdapter).self, "mailing_list").listMailingLists(domain: domain))
            }
        },
        ActionSpec("mailing_list_create", Capability(.mailingList, .create), de: "Mailingliste anlegen", en: "Create a mailing list",
                   parameters: [connectionParam, ParameterSpec("address", "Listenadresse"), ParameterSpec("members", kind: .stringArray, required: false, "Mitglieder"),
                                ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches")]) { input, _ in
            let address = try input.string("address"); let members = input.stringArray("members") ?? []; let extra = input.extra()
            return PreparedAction(target: address, preview: "Mailingliste \(address) anlegen") { a in
                try .encode(try await ActionErrors.needs(a, (any MailingListAdapter).self, "mailing_list").createMailingList(address: address, members: members, extra: extra))
            }
        },
        ActionSpec("mailing_list_update", Capability(.mailingList, .update), de: "Mitglieder einer Mailingliste setzen", en: "Set mailing list members",
                   parameters: [connectionParam, ParameterSpec("address", "Listenadresse"), ParameterSpec("members", kind: .stringArray, "Mitglieder"),
                                ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches")]) { input, _ in
            let address = try input.string("address"); let members = input.stringArray("members") ?? []; let extra = input.extra()
            return PreparedAction(target: address, preview: "Mailingliste \(address) ändern") { a in
                try .encode(try await ActionErrors.needs(a, (any MailingListAdapter).self, "mailing_list").updateMailingList(address: address, members: members, extra: extra))
            }
        },
        ActionSpec("mailing_list_prepare_delete", Capability(.mailingList, .delete), de: "Mailingliste löschen (Freigabe nötig)", en: "Delete a mailing list (requires approval)",
                   parameters: [connectionParam, ParameterSpec("address", "Listenadresse")], prepares: true) { input, _ in
            let address = try input.string("address")
            return PreparedAction(target: address, preview: "Mailingliste \(address) löschen") { a in
                try await ActionErrors.needs(a, (any MailingListAdapter).self, "mailing_list").deleteMailingList(address: address)
                return .object(["deleted": .string(address)])
            }
        },
    ]

    // MARK: FTP

    static let ftp: [ActionSpec] = [
        ActionSpec("ftp_user_list", Capability(.ftpUser, .list), de: "FTP-Zugänge auflisten", en: "List FTP users",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "FTP-Zugänge auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any FTPUserAdapter).self, "ftp_user").listFTPUsers())
            }
        },
        ActionSpec("ftp_user_create", Capability(.ftpUser, .create), de: "FTP-Zugang anlegen. Ohne Passwort wird eines erzeugt und im Schlüsselbund abgelegt.", en: "Create an FTP user. Without a password one is generated and stored in the keychain.",
                   parameters: [connectionParam, ParameterSpec("home_path", "Verzeichnis"), ParameterSpec("username", required: false, "Wunschname, falls der Provider das erlaubt"),
                                ParameterSpec("password", required: false, "Passwort (optional)"), ParameterSpec("comment", required: false, "Kommentar")]) { input, ctx in
            let home = try input.string("home_path"); let username = input.optionalString("username"); let comment = input.optionalString("comment")
            let given = input.optionalString("password"); let password = given ?? PasswordGenerator.generate()
            return PreparedAction(target: home, preview: "FTP-Zugang für \(home) anlegen") { a in
                let user = try await ActionErrors.needs(a, (any FTPUserAdapter).self, "ftp_user").createFTPUser(username: username, password: password, homePath: home, comment: comment)
                var result = try JSONValue.encode(user)
                if given == nil { try await storeGenerated(ctx, .ftpUser, user.username, password, into: &result, username: user.username, adapter: a) }
                return result
            }
        },
        ActionSpec("ftp_user_update", Capability(.ftpUser, .update), de: "FTP-Zugang ändern", en: "Update an FTP user",
                   parameters: [connectionParam, ParameterSpec("username", "Login"), ParameterSpec("password", required: false, "Neues Passwort"),
                                ParameterSpec("home_path", required: false, "Verzeichnis"), ParameterSpec("comment", required: false, "Kommentar")]) { input, _ in
            let username = try input.string("username"); let password = input.optionalString("password"); let home = input.optionalString("home_path"); let comment = input.optionalString("comment")
            return PreparedAction(target: username, preview: "FTP-Zugang \(username) ändern") { a in
                try .encode(try await ActionErrors.needs(a, (any FTPUserAdapter).self, "ftp_user").updateFTPUser(username: username, password: password, homePath: home, comment: comment))
            }
        },
        ActionSpec("ftp_user_prepare_delete", Capability(.ftpUser, .delete), de: "FTP-Zugang löschen (Freigabe nötig)", en: "Delete an FTP user (requires approval)",
                   parameters: [connectionParam, ParameterSpec("username", "Login")], prepares: true) { input, ctx in
            let username = try input.string("username")
            return PreparedAction(target: username, preview: "FTP-Zugang \(username) löschen") { a in
                try await ActionErrors.needs(a, (any FTPUserAdapter).self, "ftp_user").deleteFTPUser(username: username)
                try? await ctx.secrets.delete(connectionID: ctx.connectionID, key: PasswordGenerator.secretKey(.ftpUser, username))
                return .object(["deleted": .string(username)])
            }
        },
    ]

    // MARK: Database

    static let database: [ActionSpec] = [
        ActionSpec("database_list", Capability(.database, .list), de: "Datenbanken auflisten", en: "List databases",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "Datenbanken auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any DatabaseAdapter).self, "database").listDatabases())
            }
        },
        ActionSpec("database_create", Capability(.database, .create), de: "Datenbank anlegen. Ohne Passwort wird eines erzeugt und im Schlüsselbund abgelegt.", en: "Create a database. Without a password one is generated and stored in the keychain.",
                   parameters: [connectionParam, ParameterSpec("comment", required: false, "Kommentar, z. B. Zweck"), ParameterSpec("password", required: false, "Passwort (optional)"),
                                ParameterSpec("allowed_hosts", kind: .stringArray, required: false, "Erlaubte Hosts")]) { input, ctx in
            let comment = input.optionalString("comment"); let hosts = input.stringArray("allowed_hosts") ?? []
            let given = input.optionalString("password"); let password = given ?? PasswordGenerator.generate()
            return PreparedAction(target: comment, preview: "Datenbank anlegen\(comment.map { " (\($0))" } ?? "")") { a in
                let db = try await ActionErrors.needs(a, (any DatabaseAdapter).self, "database").createDatabase(password: password, comment: comment, allowedHosts: hosts)
                var result = try JSONValue.encode(db)
                if given == nil { try await storeGenerated(ctx, .database, db.name, password, into: &result, username: db.users.first ?? db.name, adapter: a) }
                return result
            }
        },
        ActionSpec("database_update", Capability(.database, .update), de: "Datenbank ändern (Passwort, Kommentar, Hosts)", en: "Update a database (password, comment, hosts)",
                   parameters: [connectionParam, ParameterSpec("name", "Datenbankname"), ParameterSpec("password", required: false, "Neues Passwort"),
                                ParameterSpec("comment", required: false, "Kommentar"), ParameterSpec("allowed_hosts", kind: .stringArray, required: false, "Erlaubte Hosts")]) { input, _ in
            let name = try input.string("name"); let password = input.optionalString("password"); let comment = input.optionalString("comment"); let hosts = input.stringArray("allowed_hosts")
            return PreparedAction(target: name, preview: "Datenbank \(name) ändern") { a in
                try .encode(try await ActionErrors.needs(a, (any DatabaseAdapter).self, "database").updateDatabase(name: name, password: password, comment: comment, allowedHosts: hosts))
            }
        },
        ActionSpec("database_prepare_delete", Capability(.database, .delete), de: "Datenbank löschen (Freigabe nötig)", en: "Delete a database (requires approval)",
                   parameters: [connectionParam, ParameterSpec("name", "Datenbankname")], prepares: true) { input, ctx in
            let name = try input.string("name")
            return PreparedAction(target: name, preview: "Datenbank \(name) mit allen Daten löschen") { a in
                try await ActionErrors.needs(a, (any DatabaseAdapter).self, "database").deleteDatabase(name: name)
                try? await ctx.secrets.delete(connectionID: ctx.connectionID, key: PasswordGenerator.secretKey(.database, name))
                return .object(["deleted": .string(name)])
            }
        },
    ]

    // MARK: Cron

    static let cron: [ActionSpec] = [
        ActionSpec("cron_job_list", Capability(.cronJob, .list), de: "Cronjobs auflisten", en: "List cron jobs",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "Cronjobs auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any CronJobAdapter).self, "cron_job").listCronJobs())
            }
        },
        ActionSpec("cron_job_create", Capability(.cronJob, .create), de: "Cronjob anlegen (URL-Aufruf oder Befehl, je nach Provider)", en: "Create a cron job (URL call or command, depending on the provider)",
                   parameters: [connectionParam, ParameterSpec("schedule", "Fünf Felder wie crontab: Minute Stunde Tag Monat Wochentag"),
                                ParameterSpec("url", required: false, "Aufzurufende URL"), ParameterSpec("command", required: false, "Shell-Befehl"), ParameterSpec("comment", required: false, "Kommentar")]) { input, _ in
            let schedule = try input.string("schedule"); let url = input.optionalString("url"); let command = input.optionalString("command"); let comment = input.optionalString("comment")
            guard url != nil || command != nil else { throw KastellanError.invalidArgument("url oder command fehlt") }
            return PreparedAction(target: url ?? command, preview: "Cronjob \(schedule) → \(url ?? command ?? "") anlegen") { a in
                try .encode(try await ActionErrors.needs(a, (any CronJobAdapter).self, "cron_job").createCronJob(schedule: schedule, url: url, command: command, comment: comment))
            }
        },
        ActionSpec("cron_job_update", Capability(.cronJob, .update), de: "Cronjob ändern", en: "Update a cron job",
                   parameters: [connectionParam, ParameterSpec("provider_ref", "Cronjob-Kennung"), ParameterSpec("schedule", required: false, "Zeitplan"),
                                ParameterSpec("url", required: false, "URL"), ParameterSpec("command", required: false, "Befehl"), ParameterSpec("comment", required: false, "Kommentar"),
                                ParameterSpec("active", kind: .boolean, required: false, "Aktiv")]) { input, _ in
            let ref = try input.string("provider_ref")
            let schedule = input.optionalString("schedule"); let url = input.optionalString("url"); let command = input.optionalString("command")
            let comment = input.optionalString("comment"); let active = input.optionalBool("active")
            return PreparedAction(target: ref, preview: "Cronjob \(ref) ändern") { a in
                try .encode(try await ActionErrors.needs(a, (any CronJobAdapter).self, "cron_job").updateCronJob(providerRef: ref, schedule: schedule, url: url, command: command, comment: comment, active: active))
            }
        },
        ActionSpec("cron_job_prepare_delete", Capability(.cronJob, .delete), de: "Cronjob löschen (Freigabe nötig)", en: "Delete a cron job (requires approval)",
                   parameters: [connectionParam, ParameterSpec("provider_ref", "Cronjob-Kennung")], prepares: true) { input, _ in
            let ref = try input.string("provider_ref")
            return PreparedAction(target: ref, preview: "Cronjob \(ref) löschen") { a in
                try await ActionErrors.needs(a, (any CronJobAdapter).self, "cron_job").deleteCronJob(providerRef: ref)
                return .object(["deleted": .string(ref)])
            }
        },
    ]

    // MARK: Certificate

    static let certificate: [ActionSpec] = [
        ActionSpec("certificate_list", Capability(.certificate, .list), de: "Zertifikate auflisten", en: "List certificates",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "Zertifikate auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any CertificateAdapter).self, "certificate").listCertificates())
            }
        },
        ActionSpec("certificate_update", Capability(.certificate, .update), de: "Zertifikat-Einstellungen ändern (HTTPS erzwingen, Upload über extra)", en: "Update certificate settings (force HTTPS, upload via extra)",
                   parameters: [connectionParam, ParameterSpec("hostname", "Hostname"), ParameterSpec("force_https", kind: .boolean, required: false, "HTTPS erzwingen"),
                                ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches, etwa Zertifikat und Schlüssel")]) { input, _ in
            let hostname = try input.string("hostname"); let force = input.optionalBool("force_https"); let extra = input.extra()
            return PreparedAction(target: hostname, preview: "Zertifikat-Einstellungen für \(hostname) ändern") { a in
                try .encode(try await ActionErrors.needs(a, (any CertificateAdapter).self, "certificate").updateCertificate(hostname: hostname, forceHTTPS: force, extra: extra))
            }
        },
    ]

    // MARK: Directory protection

    static let directoryProtection: [ActionSpec] = [
        ActionSpec("directory_protection_list", Capability(.directoryProtection, .list), de: "Verzeichnisschutz auflisten", en: "List directory protections",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "Verzeichnisschutz auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any DirectoryProtectionAdapter).self, "directory_protection").listDirectoryProtections())
            }
        },
        ActionSpec("directory_protection_create", Capability(.directoryProtection, .create), de: "Verzeichnisschutz anlegen", en: "Create a directory protection",
                   parameters: [connectionParam, ParameterSpec("path", "Verzeichnis"), ParameterSpec("username", "Benutzer"),
                                ParameterSpec("password", required: false, "Passwort (optional, sonst erzeugt)"), ParameterSpec("realm", required: false, "Anzeigename")]) { input, ctx in
            let path = try input.string("path"); let username = try input.string("username"); let realm = input.optionalString("realm")
            let given = input.optionalString("password"); let password = given ?? PasswordGenerator.generate()
            return PreparedAction(target: path, preview: "Verzeichnisschutz für \(path) (\(username)) anlegen") { a in
                let dp = try await ActionErrors.needs(a, (any DirectoryProtectionAdapter).self, "directory_protection").createDirectoryProtection(path: path, username: username, password: password, realm: realm)
                var result = try JSONValue.encode(dp)
                if given == nil { try await storeGenerated(ctx, .directoryProtection, "\(path)/\(username)", password, into: &result, username: username, adapter: a) }
                return result
            }
        },
        ActionSpec("directory_protection_prepare_delete", Capability(.directoryProtection, .delete), de: "Verzeichnisschutz entfernen (Freigabe nötig)", en: "Remove a directory protection (requires approval)",
                   parameters: [connectionParam, ParameterSpec("path", "Verzeichnis"), ParameterSpec("username", required: false, "Nur diesen Benutzer")], prepares: true) { input, _ in
            let path = try input.string("path"); let username = input.optionalString("username")
            return PreparedAction(target: path, preview: "Verzeichnisschutz für \(path) entfernen") { a in
                try await ActionErrors.needs(a, (any DirectoryProtectionAdapter).self, "directory_protection").deleteDirectoryProtection(path: path, username: username)
                return .object(["deleted": .string(path)])
            }
        },
    ]

    // MARK: Subaccount

    static let subaccount: [ActionSpec] = [
        ActionSpec("subaccount_list", Capability(.subaccount, .list), de: "Subaccounts auflisten", en: "List subaccounts",
                   parameters: [connectionParam]) { _, _ in
            PreparedAction(target: nil, preview: "Subaccounts auflisten") { a in
                try .encode(try await ActionErrors.needs(a, (any SubaccountAdapter).self, "subaccount").listSubaccounts())
            }
        },
        ActionSpec("subaccount_prepare_create", Capability(.subaccount, .create), de: "Subaccount anlegen (Freigabe nötig)", en: "Create a subaccount (requires approval)",
                   parameters: [connectionParam, ParameterSpec("comment", required: false, "Kommentar"), ParameterSpec("password", required: false, "Passwort (optional, sonst erzeugt)"),
                                ParameterSpec("extra", kind: .object, required: false, "Provider-Spezifisches")], prepares: true) { input, ctx in
            let comment = input.optionalString("comment"); let extra = input.extra()
            let given = input.optionalString("password"); let password = given ?? PasswordGenerator.generate()
            return PreparedAction(target: comment, preview: "Subaccount anlegen\(comment.map { " (\($0))" } ?? "")") { a in
                let acc = try await ActionErrors.needs(a, (any SubaccountAdapter).self, "subaccount").createSubaccount(password: password, comment: comment, extra: extra)
                var result = try JSONValue.encode(acc)
                if given == nil { try await storeGenerated(ctx, .subaccount, acc.login, password, into: &result, username: acc.login, adapter: a) }
                return result
            }
        },
        ActionSpec("subaccount_prepare_delete", Capability(.subaccount, .delete), de: "Subaccount löschen (Freigabe nötig)", en: "Delete a subaccount (requires approval)",
                   parameters: [connectionParam, ParameterSpec("login", "Login des Subaccounts")], prepares: true) { input, _ in
            let login = try input.string("login")
            return PreparedAction(target: login, preview: "Subaccount \(login) löschen") { a in
                try await ActionErrors.needs(a, (any SubaccountAdapter).self, "subaccount").deleteSubaccount(login: login)
                return .object(["deleted": .string(login)])
            }
        },
    ]
}

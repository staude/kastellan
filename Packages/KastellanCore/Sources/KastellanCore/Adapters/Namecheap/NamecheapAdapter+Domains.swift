import Foundation

// Domains bei Namecheap. Liste über `domains.getList` (seitenweise), Details über
// `domains.getInfo` plus `domains.getRegistrarLock`. Änderbar über `domain_update`:
// Registrar-Lock (`extra.lock`), Domain-Privacy (`extra.privacy`, beim Einschalten mit
// `extra.privacy_forward_email`) und Nameserver (`extra.nameservers` als Liste oder `default`
// für Namecheap-DNS; läuft als Freigabe). Registrieren, Verlängern, Transfer und Löschen bietet
// Kastellan nicht an.

extension NamecheapAdapter: DomainAdapter {
    /// TLDs ohne Registrar-Lock bei Namecheap (Fehler 2015280 im Probe-Lauf).
    static let tldsWithoutLock: Set<String> = ["de"]

    static func lockSupported(_ fqdn: String) -> Bool {
        guard let tld = try? NamecheapClient.split(fqdn).tld else { return false }
        return !tldsWithoutLock.contains(tld)
    }

    func listItem(_ item: NamecheapXMLElement) -> Domain {
        var extra: Extra = [:]
        if let v = NamecheapAdapter.isoDay(item["Created"]) { extra["created"] = v }
        if let v = NamecheapAdapter.isoDay(item["Expires"]) { extra["expires"] = v }
        if let v = item.bool("IsLocked") { extra["is_locked"] = .bool(v) }
        if let v = item.bool("AutoRenew") { extra["auto_renew"] = .bool(v) }
        if let v = item["WhoisGuard"] { extra["privacy"] = .string(v.lowercased()) }
        if let v = item.bool("IsPremium") { extra["is_premium"] = .bool(v) }
        let expired = item.bool("IsExpired") == true
        return Domain(ref: ref(item["ID"] ?? item["Name"] ?? ""), fqdn: (item["Name"] ?? "").lowercased(),
                      status: expired ? "expired" : "active", nameservers: [],
                      dnsManagedHere: item.bool("IsOurDNS") ?? false, mailManagedHere: false, extra: extra)
    }

    public func listDomains() async throws -> [Domain] {
        try await client.list("namecheap.domains.getList", item: "Domain").map(listItem).sorted { $0.fqdn < $1.fqdn }
    }

    public func getDomain(fqdn: String) async throws -> Domain? {
        let name = Self.normalized(fqdn)
        let info: NamecheapXMLElement
        do {
            info = try await client.call("namecheap.domains.getInfo", [("DomainName", name)])
        } catch KastellanError.notFound { return nil }
        guard let result = info.firstDescendant("DomainGetInfoResult") else { return nil }

        var extra: Extra = [:]
        if let details = result.child("DomainDetails") {
            if let v = NamecheapAdapter.isoDay(details.child("CreatedDate")?.text) { extra["created"] = v }
            if let v = NamecheapAdapter.isoDay(details.child("ExpiredDate")?.text) { extra["expires"] = v }
        }
        if let v = result.bool("IsPremium") { extra["is_premium"] = .bool(v) }
        let dns = result.child("DnsDetails")
        if let v = dns?["ProviderType"] { extra["dns_provider_type"] = .string(v) }
        if let v = dns?["EmailType"] { extra["email_type"] = .string(v) }
        if let v = dns?.int("HostCount") { extra["host_count"] = .int(v) }
        if let guard_ = result.child("Whoisguard") {
            extra["privacy"] = .string((guard_["Enabled"] ?? "").lowercased())
            if let id = guard_.child("ID")?.text, !id.isEmpty, id != "0" { extra["privacy_id"] = .string(id) }
        }
        if Self.lockSupported(name) {
            if let lock = try? await client.call("namecheap.domains.getRegistrarLock", [("DomainName", name)]),
               let status = lock.firstDescendant("DomainGetRegistrarLockResult")?.bool("RegistrarLockStatus") {
                extra["is_locked"] = .bool(status)
            }
        } else {
            extra["lock_supported"] = .bool(false)
        }
        let emailType = (dns?["EmailType"] ?? "").uppercased()
        return Domain(ref: ref(result["ID"] ?? name), fqdn: (result["DomainName"] ?? name).lowercased(),
                      status: (result["Status"] ?? "").lowercased() == "ok" ? "active" : result["Status"]?.lowercased(),
                      nameservers: dns?.children("Nameserver").map { $0.text.lowercased() } ?? [],
                      dnsManagedHere: dns?.bool("IsUsingOurDNS") ?? false,
                      mailManagedHere: emailType == "FWD" || emailType.contains("FORWARD"), extra: extra)
    }

    public func createDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        throw KastellanError.unsupported("Namecheap: Domains werden nicht über Kastellan registriert")
    }

    public func updateDomain(fqdn: String, path: String?, extra: Extra) async throws -> Domain {
        let name = Self.normalized(fqdn)
        let (sld, tld) = try NamecheapClient.split(name)
        if let ns = extra["nameservers"] {
            if ns.stringValue?.lowercased() == "default" {
                try await client.call("namecheap.domains.dns.setDefault", [("SLD", sld), ("TLD", tld)])
            } else {
                let list = Self.nameserverList(ns)
                guard list.count >= 2, list.count <= 12 else {
                    throw KastellanError.invalidArgument("Namecheap: zwei bis zwölf Nameserver angeben oder \"default\" für Namecheap-DNS")
                }
                try await client.call("namecheap.domains.dns.setCustom", [("SLD", sld), ("TLD", tld), ("Nameservers", list.joined(separator: ","))])
            }
        }
        if let lock = extra["lock"].flatMap(Self.bool) {
            guard Self.lockSupported(name) else {
                throw KastellanError.unsupported("Namecheap: Für .\(tld)-Domains gibt es keinen Registrar-Lock")
            }
            try await client.call("namecheap.domains.setRegistrarLock", [("DomainName", name), ("LockAction", lock ? "LOCK" : "UNLOCK")])
        }
        if let privacy = extra["privacy"].flatMap(Self.bool) {
            let info = try await client.call("namecheap.domains.getInfo", [("DomainName", name)])
            guard let id = info.firstDescendant("Whoisguard")?.child("ID")?.text, !id.isEmpty, id != "0" else {
                throw KastellanError.unsupported("Namecheap: Für \(name) ist kein Domain-Privacy-Schutz zugeordnet (z. B. bei .de nicht verfügbar)")
            }
            if privacy {
                guard let email = extra["privacy_forward_email"]?.stringValue, email.contains("@") else {
                    throw KastellanError.invalidArgument("Namecheap: Zum Einschalten von Domain-Privacy extra.privacy_forward_email angeben (Adresse, an die Namecheap Anfragen weiterleitet)")
                }
                try await client.call("namecheap.whoisguard.enable", [("WhoisguardID", id), ("ForwardedToEmail", email)])
            } else {
                try await client.call("namecheap.whoisguard.disable", [("WhoisguardID", id)])
            }
        }
        guard let updated = try await getDomain(fqdn: name) else { throw KastellanError.notFound("Domain \(fqdn) bei Namecheap") }
        return updated
    }

    public func deleteDomain(fqdn: String) async throws {
        throw KastellanError.unsupported("Namecheap: Domains werden nicht über Kastellan gelöscht oder gekündigt")
    }

    /// Nameserver aus `extra.nameservers`: Liste oder kommagetrennter Text, normalisiert und ohne Leereinträge.
    static func nameserverList(_ value: JSONValue) -> [String] {
        var raw: [String] = []
        if let array = value.arrayValue {
            raw = array.compactMap(\.stringValue)
        } else if let text = value.stringValue {
            raw = text.split(separator: ",").map(String.init)
        }
        return raw.map { normalized($0) }.filter { !$0.isEmpty }
    }

    static func bool(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let b): return b
        case .string(let s): return ["true", "ja", "yes", "1", "on"].contains(s.lowercased()) ? true : ["false", "nein", "no", "0", "off"].contains(s.lowercased()) ? false : nil
        case .int(let i): return i != 0
        default: return nil
        }
    }
}

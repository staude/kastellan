import Foundation
import Testing
@testable import KastellanCore

struct KASAdapterDomainTests {
    @Test func adapterMetadata() {
        #expect(KASAdapter.providerID == "allinkl")
        #expect(KASAdapter.displayName == "All-Inkl (KAS)")
        #expect(KASAdapter.settingKeys.map(\.key) == ["kas_login"])
        #expect(KASAdapter.secretKeys.map(\.key) == ["password"])
        let m = KASAdapter.capabilityMatrix
        #expect(m.supports(Capability(.domain, .list)))
        #expect(m.supports(Capability(.domain, .delete)))
        #expect(!m.supports(Capability(.domain, .setPassword)))
        #expect(m.supports(Capability(.subdomain, .create)))
        #expect(!m.supports(Capability(.subdomain, .get)))
        #expect(m.supports(Capability(.dnsZone, .list)))
        #expect(!m.supports(Capability(.dnsZone, .create)))
        #expect(m.supports(Capability(.dnsRecord, .update)))
        #expect(m.supports(Capability(.dkim, .create)))
        #expect(!m.supports(Capability(.dkim, .update)))
        #expect(!m.supports(Capability(.sshUser, .list)))
    }

    @Test func registryBuildsAdapterFromConnection() async throws {
        var registry = AdapterRegistry()
        registry.register(KASAdapter.self)
        let conn = Connection(profileID: "privat", provider: "allinkl", label: "KAS", settings: ["kas_login": "w00abcde"])
        let adapter = try registry.adapter(for: conn, secrets: InMemorySecretProvider())
        #expect(adapter is KASAdapter)
        #expect(adapter as? any DomainAdapter != nil)
        #expect(adapter as? any DKIMAdapter != nil)
        #expect(adapter as? any SSHUserAdapter == nil)
    }

    @Test func builtinRegistryKnowsAllInkl() {
        let entry = BuiltinAdapters.registry.entry(for: "allinkl")
        #expect(entry?.displayName == "All-Inkl (KAS)")
        #expect(entry?.capabilityMatrix.supports(Capability(.dnsRecord, .list)) == true)
    }

    @Test func healthCheckUsesServerInformation() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.mapArrayResponse("get_server_information", items: [["server_software": "Apache", "php_version": "8.3"]]),
        ])
        let health = await adapter.healthCheck()
        #expect(health.ok)
        #expect(health.connectionID == "conn-kas")
        #expect(health.message.contains("w00abcde"))
        #expect(health.message.contains("PHP 8.3"))
        #expect(await transport.requests.last?.action == "get_server_information")
    }

    @Test func healthCheckReportsFailure() async throws {
        let (adapter, _) = try KASFixtures.adapter([KASFixtures.fault("server_error", detail: "Wartung")])
        let health = await adapter.healthCheck()
        #expect(!health.ok)
        #expect(health.message.contains("server_error: Wartung"))
    }

    @Test func missingPasswordIsUnauthorized() async throws {
        let conn = Connection(id: "c-leer", profileID: "privat", provider: "allinkl", label: "", settings: ["kas_login": "w00abcde"])
        let adapter = KASAdapter(connection: conn, secrets: InMemorySecretProvider())
        await #expect(throws: KastellanError.unauthorized("Kein KAS-Passwort im Schlüsselbund für Verbindung c-leer")) {
            try await adapter.listDomains()
        }
    }

    @Test func missingLoginIsInvalidArgument() async throws {
        let conn = Connection(id: "c-ohne", profileID: "privat", provider: "allinkl", label: "")
        let adapter = KASAdapter(connection: conn, secrets: InMemorySecretProvider())
        await #expect(throws: KastellanError.self) { try await adapter.listDomains() }
    }

    // MARK: - Domain

    @Test func listDomainsMapsFixture() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_domains")])
        let domains = try await adapter.listDomains()
        #expect(domains.map(\.fqdn) == ["beispiel-shop.com", "mustermann.example"])
        let first = try #require(domains.first)
        #expect(first.ref == ResourceRef(connectionID: "conn-kas", providerRef: "beispiel-shop.com"))
        #expect(first.status == "active")
        #expect(first.path == "/beispiel-shop.com/")
        #expect(first.extra["dkim_selector"] == .string("kas202502031742"))
        #expect(first.extra["php_version"] == .string("8.3"))
        #expect(first.extra["ssl_certificate_sni"] == .string("N"))
        #expect(first.extra["domain_name"] == nil)
        #expect(first.extra["is_active"] == nil)
    }

    @Test func getDomainIsCaseInsensitive() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_domains"), try KASFixtures.response("get_domains")])
        #expect(try await adapter.getDomain(fqdn: "Mustermann.Example")?.fqdn == "mustermann.example")
        #expect(try await adapter.getDomain(fqdn: "fehlt.de") == nil)
    }

    @Test func createDomainSendsParamsAndRereads() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_domain", returnInfo: "TRUE"),
            try KASFixtures.response("get_domains"),
        ])
        let domain = try await adapter.createDomain(fqdn: "beispiel-shop.com", path: "/beispiel-shop.com/", extra: ["php_version": .string("8.3")])
        #expect(domain.fqdn == "beispiel-shop.com")
        let add = try #require(await transport.requests.first { $0.action == "add_domain" })
        #expect(add.requestParams == ["domain_name": "beispiel-shop.com", "domain_path": "/beispiel-shop.com/", "php_version": "8.3"])
    }

    @Test func updateAndDeleteDomain() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("update_domain", returnInfo: "TRUE"),
            try KASFixtures.response("get_domains"),
            KASFixtures.scalarResponse("delete_domain", returnInfo: "TRUE"),
        ])
        let updated = try await adapter.updateDomain(fqdn: "beispiel-shop.com", path: "/neu/", extra: [:])
        #expect(updated.fqdn == "beispiel-shop.com")
        try await adapter.deleteDomain(fqdn: "beispiel-shop.com")
        let actions = await transport.requests.compactMap(\.action)
        #expect(actions == ["update_domain", "get_domains", "delete_domain"])
        #expect(await transport.requests.last?.requestParams == ["domain_name": "beispiel-shop.com"])
        #expect(await transport.requests[1].requestParams == ["domain_name": "beispiel-shop.com", "domain_path": "/neu/"])
    }

    @Test func providerFaultBecomesKastellanError() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.data("fault-zone_not_found")])
        await #expect(throws: KastellanError.provider("zone_not_found: gibt-es-nicht-example.com")) {
            try await adapter.listRecords(zone: "gibt-es-nicht-example.com")
        }
    }

    // MARK: - Subdomain

    @Test func listSubdomainsDerivesParent() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_subdomains")])
        let subs = try await adapter.listSubdomains(parent: nil)
        #expect(subs.count == 2)
        let planer = try #require(subs.first)
        #expect(planer.fqdn == "planer.beispiel-app.de")
        #expect(planer.parent == "beispiel-app.de")
        #expect(planer.targetPath == "/planer.beispiel-app.de/public/")
        #expect(planer.redirect == nil)
        #expect(planer.ref.providerRef == "planer.beispiel-app.de")
        #expect(planer.extra["ssl_certificate_sni"] == .string("Y"))
        #expect(planer.extra["ssl_certificate_sni_crt"] == .null)
        #expect(planer.extra["ssl_certificate_sni_key"] == nil)
        #expect(planer.extra["php_version"] == .string("8.5"))
        #expect(planer.extra["subdomain_redirect_status"] == .string("0"))
    }

    @Test func listSubdomainsFiltersByParent() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_subdomains"), try KASFixtures.response("get_subdomains")])
        let filtered = try await adapter.listSubdomains(parent: "beispiel-aktion.org")
        #expect(filtered.map(\.fqdn) == ["cloud.beispiel-aktion.org"])
        #expect(try await adapter.listSubdomains(parent: "andere.de").isEmpty)
    }

    @Test func createSubdomainSplitsLabelAndParent() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_subdomain", returnInfo: "TRUE"),
            try KASFixtures.response("get_subdomains"),
        ])
        let sub = try await adapter.createSubdomain(fqdn: "planer.beispiel-app.de", targetPath: "/planer/", redirect: nil, extra: [:])
        #expect(sub.parent == "beispiel-app.de")
        let add = try #require(await transport.requests.first { $0.action == "add_subdomain" })
        #expect(add.requestParams == [
            "subdomain_name": "planer", "domain_name": "beispiel-app.de",
            "subdomain_path": "/planer/", "subdomain_redirect_status": "0",
        ])
    }

    @Test func createSubdomainWithRedirect() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_subdomain", returnInfo: "TRUE"),
            KASFixtures.mapArrayResponse("get_subdomains", items: []),
        ])
        let sub = try await adapter.createSubdomain(fqdn: "alt.example.com", targetPath: nil, redirect: "https://example.com/", extra: [:])
        #expect(sub.redirect == "https://example.com/")
        let add = try #require(await transport.requests.first { $0.action == "add_subdomain" })
        #expect(add.requestParams["subdomain_path"] == "https://example.com/")
        #expect(add.requestParams["subdomain_redirect_status"] == "301")
    }

    @Test func createSubdomainRejectsTooShortNames() async throws {
        let (adapter, _) = try KASFixtures.adapter([])
        await #expect(throws: KastellanError.self) {
            try await adapter.createSubdomain(fqdn: "example.com", targetPath: nil, redirect: nil, extra: [:])
        }
    }

    @Test func updateAndDeleteSubdomain() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("update_subdomain", returnInfo: "TRUE"),
            try KASFixtures.response("get_subdomains"),
            KASFixtures.scalarResponse("delete_subdomain", returnInfo: "TRUE"),
        ])
        _ = try await adapter.updateSubdomain(fqdn: "cloud.beispiel-aktion.org", targetPath: "/neu/", redirect: nil, extra: [:])
        try await adapter.deleteSubdomain(fqdn: "cloud.beispiel-aktion.org")
        let requests = await transport.requests
        #expect(requests[1].requestParams == ["subdomain_name": "cloud.beispiel-aktion.org", "subdomain_path": "/neu/", "subdomain_redirect_status": "0"])
        #expect(requests.last?.requestParams == ["subdomain_name": "cloud.beispiel-aktion.org"])
    }

    // MARK: - DNS

    @Test func listZonesFromDomains() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_domains")])
        let zones = try await adapter.listZones()
        #expect(zones.map(\.zone) == ["beispiel-shop.com", "mustermann.example"])
        #expect(zones.first?.ref.providerRef == "beispiel-shop.com")
    }

    @Test func listRecordsUsesTrailingDotAndApex() async throws {
        let (adapter, transport) = try KASFixtures.adapter([try KASFixtures.response("get_dns_settings")])
        let records = try await adapter.listRecords(zone: "example.com")
        #expect(await transport.requests.last?.requestParams == ["zone_host": "example.com."])
        #expect(records.count == 2)
        let apex = try #require(records.first)
        #expect(apex.name == "@")
        #expect(apex.zone == "example.com")
        #expect(apex.type == "A")
        #expect(apex.content == "192.0.2.45")
        #expect(apex.priority == nil)
        #expect(apex.ttl == nil)
        #expect(apex.ref.providerRef == "120313043")
        #expect(apex.extra["changeable"] == .bool(true))
        #expect(apex.extra["deleteable"] == .bool(true))
        let wildcard = try #require(records.last)
        #expect(wildcard.name == "*")
        #expect(wildcard.type == "CNAME")
        #expect(wildcard.content == "w00abcde.kasserver.com.")
    }

    @Test func listRecordsAcceptsZoneWithTrailingDot() async throws {
        let (adapter, transport) = try KASFixtures.adapter([try KASFixtures.response("get_dns_settings")])
        let records = try await adapter.listRecords(zone: "Example.com.")
        #expect(await transport.requests.last?.requestParams == ["zone_host": "example.com."])
        #expect(records.first?.zone == "example.com")
    }

    @Test func mxRecordsCarryPriorityAndProtectedFlag() async throws {
        let (adapter, _) = try KASFixtures.adapter([
            KASFixtures.mapArrayResponse("get_dns_settings", items: [[
                "record_zone": "example.com", "record_name": nil, "record_type": "MX", "record_data": "mail.example.com.",
                "record_aux": "10", "record_id": "1", "record_changeable": "N", "record_deleteable": "N",
            ]]),
        ])
        let mx = try #require(try await adapter.listRecords(zone: "example.com").first)
        #expect(mx.priority == 10)
        #expect(mx.isProtected)
        #expect(mx.extra["changeable"] == .bool(false))
        #expect(mx.extra["record_aux"] == nil)
    }

    @Test func createRecordSendsApexAsEmptyNameAndUsesReturnedID() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_dns_settings", returnInfo: "120313099"),
        ])
        let record = try await adapter.createRecord(zone: "example.com", name: "@", type: "mx", content: "mail.example.com.", ttl: 3600, priority: 10)
        #expect(record.ref.providerRef == "120313099")
        #expect(record.name == "@")
        #expect(record.type == "MX")
        #expect(record.priority == 10)
        let add = try #require(await transport.requests.last)
        #expect(add.action == "add_dns_settings")
        #expect(add.requestParams == [
            "zone_host": "example.com.", "record_type": "MX", "record_name": "", "record_data": "mail.example.com.", "record_aux": "10",
        ])
    }

    @Test func createRecordWithoutIDRereadsZone() async throws {
        let (adapter, _) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_dns_settings", returnInfo: ""),
            try KASFixtures.response("get_dns_settings"),
        ])
        let record = try await adapter.createRecord(zone: "example.com", name: "*", type: "CNAME", content: "w00abcde.kasserver.com.", ttl: nil, priority: nil)
        #expect(record.ref.providerRef == "120313045")
    }

    @Test func updateRecordReadsCurrentStateFirst() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            try KASFixtures.response("get_dns_settings"),
            KASFixtures.scalarResponse("update_dns_settings", returnInfo: "TRUE"),
        ])
        let updated = try await adapter.updateRecord(zone: "example.com", providerRef: "120313043", content: "1.2.3.4", ttl: nil, priority: nil)
        #expect(updated.content == "1.2.3.4")
        #expect(updated.name == "@")
        #expect(updated.ref.providerRef == "120313043")
        let update = try #require(await transport.requests.last)
        #expect(update.action == "update_dns_settings")
        #expect(update.requestParams == ["record_id": "120313043", "record_name": "", "record_data": "1.2.3.4", "record_aux": "0"])
    }

    @Test func updateUnknownRecordIsNotFound() async throws {
        let (adapter, _) = try KASFixtures.adapter([try KASFixtures.response("get_dns_settings")])
        await #expect(throws: KastellanError.notFound("DNS-Record 999 in Zone example.com")) {
            try await adapter.updateRecord(zone: "example.com", providerRef: "999", content: "x", ttl: nil, priority: nil)
        }
    }

    @Test func deleteRecordAndApplyChanges() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_dns_settings", returnInfo: "7"),
            KASFixtures.scalarResponse("delete_dns_settings", returnInfo: "TRUE"),
        ])
        let touched = try await adapter.applyChanges(zone: "example.com", changes: [
            .create(name: "www", type: "A", content: "1.2.3.4", ttl: nil, priority: nil),
            .delete(providerRef: "120313045"),
        ])
        #expect(touched.map(\.ref.providerRef) == ["7"])
        let requests = await transport.requests
        #expect(requests.last?.action == "delete_dns_settings")
        #expect(requests.last?.requestParams == ["record_id": "120313045"])
    }

    // MARK: - DKIM

    @Test func getDKIMMapsFixture() async throws {
        let (adapter, transport) = try KASFixtures.adapter([try KASFixtures.response("get_dkim")])
        let key = try #require(try await adapter.getDKIM(domain: "example.com"))
        #expect(await transport.requests.last?.requestParams == ["host": "example.com"])
        #expect(key.domain == "example.com")
        #expect(key.selector == "kas202609061725")
        #expect(key.publicKey.hasPrefix("MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A"))
        #expect(key.recordName == "kas202609061725._domainkey")
        #expect(key.txtRecord.hasPrefix("v=DKIM1; k=rsa; p=MIIBIjAN"))
        #expect(key.ref.providerRef == "example.com/kas202609061725")
        let until = try #require(key.validUntil)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let parts = cal.dateComponents([.year, .month, .day], from: until)
        #expect(parts.year == 2027 && parts.month == 3 && parts.day == 5)
    }

    @Test func getDKIMWithoutKeyIsNil() async throws {
        let (adapter, _) = try KASFixtures.adapter([KASFixtures.mapArrayResponse("get_dkim", items: [])])
        #expect(try await adapter.getDKIM(domain: "ohne-dkim.de") == nil)
    }

    @Test func createDKIMCallsAddThenGet() async throws {
        let (adapter, transport) = try KASFixtures.adapter([
            KASFixtures.scalarResponse("add_dkim", returnInfo: "TRUE"),
            try KASFixtures.response("get_dkim"),
        ])
        let key = try await adapter.createDKIM(domain: "example.com.")
        #expect(key.selector == "kas202609061725")
        let add = try #require(await transport.requests.first { $0.action == "add_dkim" })
        #expect(add.requestParams == ["host": "example.com", "check_foreign_nameserver": "N"])
    }

    @Test func unknownDKIMFunctionIsUnsupported() async throws {
        let (adapter, _) = try KASFixtures.adapter([KASFixtures.fault("unknown_action", detail: "add_dkim")])
        let error = await #expect(throws: KastellanError.self) {
            try await adapter.createDKIM(domain: "example.com")
        }
        guard case .unsupported(let message)? = error else {
            Issue.record("Erwartet unsupported, bekommen \(String(describing: error))")
            return
        }
        #expect(message.contains("add_dkim"))
    }

    @Test func deleteDKIMSendsHost() async throws {
        let (adapter, transport) = try KASFixtures.adapter([KASFixtures.scalarResponse("delete_dkim", returnInfo: "TRUE")])
        try await adapter.deleteDKIM(domain: "example.com")
        #expect(await transport.requests.last?.action == "delete_dkim")
        #expect(await transport.requests.last?.requestParams == ["host": "example.com"])
    }

    @Test func extraNeverContainsPasswords() {
        let item = KASValue.map(["mail_login": .scalar("m1"), "mail_password": .scalar("geheim"), "ftp_passwort": .scalar("x"), "note": .scalar("ok")])
        let extra = KASAdapter.extra(from: item, excluding: ["mail_login"])
        #expect(extra == ["note": .string("ok")])
    }
}

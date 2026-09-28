import Foundation
import Testing
@testable import KastellanCore

struct CloudflareAdapterCertificateTests {
    let zoneID = CloudflareFixtures.zoneID
    let secondZoneID = "9a7806061c88ada191ed06f989cc3dac"

    @Test func listCertificatesCombinesUniversalPacksAndAlwaysHTTPS() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-list"),
            try CloudflareFixtures.response("ssl-universal_settings"),
            try CloudflareFixtures.response("ssl-certificate_packs"),
            try CloudflareFixtures.response("settings-always_use_https-off"),
            try CloudflareFixtures.response("ssl-universal_settings-disabled"),
            try CloudflareFixtures.response("ssl-certificate_packs-empty"),
            try CloudflareFixtures.response("settings-always_use_https-on"),
        ])
        let certificates = try await adapter.listCertificates()
        #expect(await transport.calls == [
            "GET /zones",
            "GET /zones/\(zoneID)/ssl/universal/settings",
            "GET /zones/\(zoneID)/ssl/certificate_packs",
            "GET /zones/\(zoneID)/settings/always_use_https",
            "GET /zones/\(secondZoneID)/ssl/universal/settings",
            "GET /zones/\(secondZoneID)/ssl/certificate_packs",
            "GET /zones/\(secondZoneID)/settings/always_use_https",
        ])
        #expect(await transport.requests[2].query == ["status": "all"])
        #expect(certificates.map(\.hostname) == ["example.com", "beispiel-zone.de"])

        let first = certificates[0]
        #expect(first.ref == ResourceRef(connectionID: "conn-cf", providerRef: zoneID))
        #expect(first.issuer == "LetsEncrypt")
        #expect(first.validUntil == CloudflareAdapter.date("2026-11-13T06:59:59Z"))
        #expect(first.autoRenew == true)
        #expect(first.forceHTTPS == false)
        #expect(first.extra["status"] == .string("active"))
        #expect(first.extra["type"] == .string("universal"))
        #expect(first.extra["certificate_authority"] == .string("lets_encrypt"))
        #expect(first.extra["validation_method"] == .string("txt"))
        #expect(first.extra["hosts"] == .array([.string("example.com"), .string("*.example.com")]))
        #expect(first.extra["packs"] == .int(2))
        #expect(first.extra["pack_id"] == .string("3822ff90-ea29-44df-9e55-21300bb9419b"))

        let second = certificates[1]
        #expect(second.issuer == nil)
        #expect(second.validUntil == nil)
        #expect(second.autoRenew == false)
        #expect(second.forceHTTPS == true)
        #expect(second.extra["status"] == .string("none"))
        #expect(second.extra["packs"] == .int(0))
        #expect(second.extra["type"] == nil)
    }

    @Test func updateCertificateSetsAlwaysUseHTTPSAndRereads() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("settings-always_use_https-on"),
            try CloudflareFixtures.response("ssl-universal_settings"),
            try CloudflareFixtures.response("ssl-certificate_packs"),
            try CloudflareFixtures.response("settings-always_use_https-on"),
        ])
        let certificate = try await adapter.updateCertificate(hostname: "example.com", forceHTTPS: true, extra: [:])
        let patch = await transport.requests[1]
        #expect(patch.method == "PATCH")
        #expect(patch.path == "/zones/\(zoneID)/settings/always_use_https")
        #expect(patch.object == ["value": .string("on")])
        #expect(certificate.forceHTTPS == true)
        #expect(certificate.hostname == "example.com")
        #expect(certificate.issuer == "LetsEncrypt")
    }

    @Test func updateCertificateOffSendsOffValue() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("settings-always_use_https-off"),
            try CloudflareFixtures.response("ssl-universal_settings"),
            try CloudflareFixtures.response("ssl-certificate_packs"),
            try CloudflareFixtures.response("settings-always_use_https-off"),
        ])
        let certificate = try await adapter.updateCertificate(hostname: "example.com", forceHTTPS: false, extra: [:])
        #expect(await transport.requests[1].object == ["value": .string("off")])
        #expect(certificate.forceHTTPS == false)
    }

    @Test func updateCertificateWithoutChangeOnlyReads() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([
            try CloudflareFixtures.response("zones-by_name"),
            try CloudflareFixtures.response("ssl-universal_settings"),
            try CloudflareFixtures.response("ssl-certificate_packs"),
            try CloudflareFixtures.response("settings-always_use_https-off"),
        ])
        _ = try await adapter.updateCertificate(hostname: "example.com", forceHTTPS: nil, extra: [:])
        #expect(await transport.calls.filter { $0.hasPrefix("PATCH") }.isEmpty)
    }

    @Test func updateCertificateWithExtraIsUnsupported() async throws {
        let (adapter, transport) = CloudflareFixtures.adapter([])
        await #expect(throws: KastellanError.unsupported("Cloudflare kann bei Zertifikaten nur force_https ändern, nicht hsts, upload")) {
            try await adapter.updateCertificate(hostname: "example.com", forceHTTPS: true, extra: ["upload": .string("x"), "hsts": .bool(true)])
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func primaryPackPrefersActiveUniversal() throws {
        let packs = try JSONDecoder().decode([CloudflareCertificatePack].self, from: Data("""
        [{"id": "adv", "type": "advanced", "status": "active"}, {"id": "uni", "type": "universal", "status": "active"}, {"id": "old", "type": "universal", "status": "expired"}]
        """.utf8))
        #expect(CloudflareAdapter.primaryPack(packs)?.id == "uni")
        #expect(CloudflareAdapter.primaryPack(Array(packs.prefix(1)))?.id == "adv")
        #expect(CloudflareAdapter.primaryPack([packs[2]])?.id == "old")
        #expect(CloudflareAdapter.primaryPack([]) == nil)
    }

    @Test func dateParsingHandlesFractionalSeconds() {
        let plain = CloudflareAdapter.date("2026-11-13T06:59:59Z")
        #expect(plain != nil)
        #expect(CloudflareAdapter.date("2026-11-13T06:59:59.000000Z") == plain)
        #expect(CloudflareAdapter.date("2026-11-13T06:59:59.123Z") != nil)
        #expect(CloudflareAdapter.date("") == nil)
        #expect(CloudflareAdapter.date("gestern") == nil)
        #expect(plain?.timeIntervalSince1970 == 1_794_553_199)
    }
}

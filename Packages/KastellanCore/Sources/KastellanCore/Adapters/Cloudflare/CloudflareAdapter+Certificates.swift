import Foundation

// Zertifikate je Zone aus Universal SSL und den Certificate Packs
// (https://developers.cloudflare.com/api/resources/ssl/). Cloudflare stellt und erneuert die
// Zertifikate selbst; `auto_renew` spiegelt, ob Universal SSL eingeschaltet ist. Änderbar ist nur
// `force_https` über die Zonen-Einstellung `always_use_https`.

extension CloudflareAdapter: CertificateAdapter {
    /// Zertifikat einer Zone aus drei Aufrufen: Universal-SSL-Schalter, Certificate Packs, `always_use_https`.
    func certificate(zone: String) async throws -> Certificate {
        let z = Self.zoneName(zone)
        let id = try await zoneID(z)
        let universal: CloudflareUniversalSSLSettings = try await client.get("/zones/\(id)/ssl/universal/settings")
        let packs: [CloudflareCertificatePack] = try await client.get("/zones/\(id)/ssl/certificate_packs", query: ["status": "all"])
        let alwaysHTTPS: CloudflareZoneSetting = try await client.get("/zones/\(id)/settings/always_use_https")
        return Self.certificate(ref: ref(id), zone: z, universal: universal, packs: packs, alwaysHTTPS: alwaysHTTPS)
    }

    /// Bevorzugt das aktive Universal-Pack, sonst irgendein aktives, sonst das erste.
    static func primaryPack(_ packs: [CloudflareCertificatePack]) -> CloudflareCertificatePack? {
        let active = packs.filter { ($0.status ?? "").lowercased() == "active" }
        return active.first { ($0.type ?? "").lowercased() == "universal" } ?? active.first ?? packs.first
    }

    static func certificate(ref: ResourceRef, zone: String, universal: CloudflareUniversalSSLSettings,
                            packs: [CloudflareCertificatePack], alwaysHTTPS: CloudflareZoneSetting) -> Certificate {
        let pack = primaryPack(packs)
        let certs = pack?.certificates ?? []
        let issuer = certs.first { $0.issuer?.isEmpty == false }?.issuer ?? pack?.certificateAuthority
        let validUntil = certs.compactMap { date($0.expiresOn) }.min()

        var extra: Extra = ["status": .string(pack?.status ?? "none"), "packs": .int(packs.count)]
        if let type = pack?.type { extra["type"] = .string(type) }
        if let ca = pack?.certificateAuthority { extra["certificate_authority"] = .string(ca) }
        if let method = pack?.validationMethod { extra["validation_method"] = .string(method) }
        if let hosts = pack?.hosts, !hosts.isEmpty { extra["hosts"] = .array(hosts.map(JSONValue.string)) }
        if let packID = pack?.id { extra["pack_id"] = .string(packID) }

        return Certificate(
            ref: ref,
            hostname: zone,
            issuer: issuer,
            validUntil: validUntil,
            autoRenew: universal.enabled,
            forceHTTPS: alwaysHTTPS.value?.stringValue.map { $0.lowercased() == "on" },
            extra: extra
        )
    }

    public func listCertificates() async throws -> [Certificate] {
        var result: [Certificate] = []
        for zone in try await listZones() {
            result.append(try await certificate(zone: zone.zone))
        }
        return result
    }

    /// Nur `force_https` ist änderbar (`PATCH /zones/{zone_id}/settings/always_use_https`).
    public func updateCertificate(hostname: String, forceHTTPS: Bool?, extra: Extra) async throws -> Certificate {
        let unsupported = extra.keys.sorted()
        guard unsupported.isEmpty else {
            throw KastellanError.unsupported("Cloudflare kann bei Zertifikaten nur force_https ändern, nicht \(unsupported.joined(separator: ", "))")
        }
        let z = Self.zoneName(hostname)
        if let forceHTTPS {
            let id = try await zoneID(z)
            let _: CloudflareZoneSetting = try await client.patch("/zones/\(id)/settings/always_use_https",
                                                                  body: .object(["value": .string(forceHTTPS ? "on" : "off")]))
        }
        return try await certificate(zone: z)
    }
}

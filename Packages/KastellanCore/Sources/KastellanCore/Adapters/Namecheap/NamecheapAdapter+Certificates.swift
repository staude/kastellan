import Foundation

// Zertifikate bei Namecheap, nur lesend über `ssl.getList` (seitenweise). Kauf, Aktivierung und
// Verlängerung kosten Geld und bleiben im Namecheap-Panel. Der Hostname steht schon in der Liste,
// `ssl.getInfo` je Zertifikat spart Kastellan sich deshalb.

extension NamecheapAdapter: CertificateAdapter {
    public func listCertificates() async throws -> [Certificate] {
        try await client.list("namecheap.ssl.getList", item: "SSL").map { ssl in
            var extra: Extra = [:]
            if let v = ssl["CertificateID"] { extra["certificate_id"] = .string(v) }
            if let v = ssl["Status"] { extra["status"] = .string(v.lowercased()) }
            if let v = NamecheapAdapter.isoDay(ssl["PurchaseDate"]) { extra["purchased"] = v }
            if let v = NamecheapAdapter.isoDay(ssl["ActivationExpireDate"]) { extra["activation_expires"] = v }
            if let v = ssl.bool("IsExpiredYN") { extra["expired"] = .bool(v) }
            let host = (ssl["HostName"] ?? "").lowercased()
            return Certificate(ref: ref(ssl["CertificateID"] ?? host), hostname: host.isEmpty ? "(nicht aktiviert)" : host,
                               issuer: ssl["SSLType"], validUntil: NamecheapAdapter.date(ssl["ExpireDate"]), autoRenew: nil, forceHTTPS: nil, extra: extra)
        }.sorted { $0.hostname < $1.hostname }
    }

    public func updateCertificate(hostname: String, forceHTTPS: Bool?, extra: Extra) async throws -> Certificate {
        throw KastellanError.unsupported("Namecheap: Zertifikate werden im Namecheap-Panel gekauft und aktiviert, Kastellan liest sie nur")
    }
}

import Foundation

// Rohe Cloudflare-Objekte, wie die API sie liefert (Feldnamen laut developers.cloudflare.com/api).
// Nur die Felder, die Kastellan abbildet; alles Weitere ignoriert der Decoder.

/// `GET /zones` (https://developers.cloudflare.com/api/resources/zones/).
public struct CloudflareZone: Decodable, Sendable {
    public struct Plan: Decodable, Sendable {
        public let name: String?
    }

    public let id: String
    public let name: String
    public let status: String?
    public let plan: Plan?
    public let nameServers: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, status, plan
        case nameServers = "name_servers"
    }
}

/// `GET /zones/{zone_id}/dns_records` (https://developers.cloudflare.com/api/resources/dns/subresources/records/).
/// `name` ist der volle Hostname, `ttl` 1 bedeutet „automatisch“.
public struct CloudflareDNSRecord: Decodable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let content: String?
    public let ttl: Int?
    public let priority: Int?
    public let proxied: Bool?
    public let proxiable: Bool?
    public let comment: String?
    public let zoneName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, content, ttl, priority, proxied, proxiable, comment
        case zoneName = "zone_name"
    }
}

/// Ergebnis von `POST /zones/{zone_id}/dns_records/batch`: je Aktion die betroffenen Records.
public struct CloudflareDNSBatchResult: Decodable, Sendable {
    public let deletes: [CloudflareDNSRecord]?
    public let patches: [CloudflareDNSRecord]?
    public let puts: [CloudflareDNSRecord]?
    public let posts: [CloudflareDNSRecord]?
}

/// Antwort auf `DELETE /zones/{zone_id}/dns_records/{id}`: nur die ID.
public struct CloudflareDeletedObject: Decodable, Sendable {
    public let id: String?
}

/// Regel aus `GET /zones/{zone_id}/email/routing/rules` und `.../rules/catch_all`
/// (https://developers.cloudflare.com/api/resources/email_routing/). Matcher `literal` auf `to`,
/// beim Catch-all `all`; Aktionen `forward` (Zieladressen), `worker` oder `drop`.
public struct CloudflareEmailRule: Decodable, Sendable {
    public struct Matcher: Decodable, Sendable {
        public let type: String
        public let field: String?
        public let value: String?
    }

    public struct Action: Decodable, Sendable {
        public let type: String
        public let value: [String]?
    }

    public let id: String?
    public let tag: String?
    public let name: String?
    public let enabled: Bool?
    public let priority: Int?
    public let matchers: [Matcher]?
    public let actions: [Action]?

    public var isCatchAll: Bool { (matchers ?? []).contains { $0.type == "all" } }

    /// Adresse aus dem `literal`-Matcher auf `to`.
    public var literalAddress: String? {
        (matchers ?? []).first { $0.type == "literal" && ($0.field ?? "to") == "to" }?.value
    }

    /// Alle Ziele der `forward`-Aktionen.
    public var forwardTargets: [String] {
        (actions ?? []).filter { $0.type == "forward" }.flatMap { $0.value ?? [] }
    }
}

/// Zieladresse aus `GET /accounts/{account_id}/email/routing/addresses`. `verified` ist der
/// Zeitpunkt der Bestätigung oder `null`.
public struct CloudflareEmailAddress: Decodable, Sendable {
    public let id: String?
    public let tag: String?
    public let email: String
    public let verified: JSONValue?

    public var isVerified: Bool {
        switch verified {
        case .none, .null?, .bool(false)?: false
        case .string(let s)?: !s.isEmpty
        default: true
        }
    }
}

/// `GET /zones/{zone_id}/ssl/universal/settings`.
public struct CloudflareUniversalSSLSettings: Decodable, Sendable {
    public let enabled: Bool?
}

/// Eintrag aus `GET /zones/{zone_id}/ssl/certificate_packs` (https://developers.cloudflare.com/api/resources/ssl/).
public struct CloudflareCertificatePack: Decodable, Sendable {
    public struct Certificate: Decodable, Sendable {
        public let id: String?
        public let issuer: String?
        public let status: String?
        public let expiresOn: String?
        public let hosts: [String]?

        enum CodingKeys: String, CodingKey {
            case id, issuer, status, hosts
            case expiresOn = "expires_on"
        }
    }

    public let id: String
    public let type: String?
    public let status: String?
    public let hosts: [String]?
    public let certificateAuthority: String?
    public let validationMethod: String?
    public let primaryCertificate: String?
    public let certificates: [Certificate]?

    enum CodingKeys: String, CodingKey {
        case id, type, status, hosts, certificates
        case certificateAuthority = "certificate_authority"
        case validationMethod = "validation_method"
        case primaryCertificate = "primary_certificate"
    }
}

/// Zonen-Einstellung wie `GET/PATCH /zones/{zone_id}/settings/always_use_https`.
public struct CloudflareZoneSetting: Decodable, Sendable {
    public let id: String?
    public let value: JSONValue?
    public let editable: Bool?
}

/// `GET /user/tokens/verify`: `status` ist `active`, `disabled` oder `expired`.
public struct CloudflareTokenVerification: Decodable, Sendable {
    public let id: String?
    public let status: String
    public let expiresOn: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case expiresOn = "expires_on"
    }
}

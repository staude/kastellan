import Foundation

// Subdomains als Ingress und Zertifikate bei Mittwald. `POST /ingresses {hostname, projectId,
// paths[{path, target}]}` mit Ziel App-Installation (`extra.app_installation_id`), URL
// (Weiterleitung) oder Standardseite; Pfade über `PATCH /ingresses/{id}/paths`, TLS über
// `PATCH /ingresses/{id}/tls` (`{acme: true}` oder `{certificateId}`), Löschen über `DELETE`.
// Beim Anlegen legt Mittwald eine DNS-Zone an. Fremde Domains brauchen den Ownership-TXT-Record
// (`ownership.txtRecord` im Ergebnis) und `actions/verify-ownership`. Eigene Zertifikate über
// `POST /certificate-requests {projectId, certificate, privateKey}`.

extension MittwaldAdapter {
    static func target(installation: String?, redirect: String?, container: String?) -> JSONValue {
        if let redirect, !redirect.isEmpty { return .object(["url": .string(redirect)]) }
        if let installation, !installation.isEmpty { return .object(["installationId": .string(installation)]) }
        if let container, !container.isEmpty { return .object(["container": .object(["id": .string(container), "portProtocol": .string("80/http")])]) }
        return .object(["useDefaultPage": .bool(true)])
    }

    /// `targetPath` aus Kastellan: `app:<id>`, `container:<id>`, `default-page` oder leer.
    static func parseTargetPath(_ path: String?) -> (installation: String?, container: String?) {
        guard let path else { return (nil, nil) }
        if path.hasPrefix("app:") { return (String(path.dropFirst(4)), nil) }
        if path.hasPrefix("container:") { return (nil, String(path.dropFirst(10))) }
        return (nil, nil)
    }

    func ingress(named host: String) async throws -> JSONValue {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        for pid in try await projectIDs() {
            if let item = try await client.list("/ingresses", query: [("projectId", pid), ("hostnameSubstring", h)]).first(where: { $0.string("hostname")?.lowercased() == h }) {
                return item
            }
        }
        throw KastellanError.notFound("Ingress \(host) bei Mittwald")
    }

    /// Einzige App-Installation im Projekt als Standardziel, sonst nil.
    func defaultInstallation(project: String) async throws -> String? {
        let installations = try await client.list("/projects/\(project)/app-installations")
        return installations.count == 1 ? installations[0].string("id") : nil
    }
}

extension MittwaldAdapter {
    public func createSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain {
        let host = fqdn.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let project = try await projectID(extra)
        let parsed = Self.parseTargetPath(targetPath)
        var installation = extra["app_installation_id"]?.stringValue ?? parsed.installation
        if installation == nil, redirect == nil, parsed.container == nil, targetPath != "default-page" {
            installation = try await defaultInstallation(project: project)
        }
        let paths: JSONValue = .array([.object(["path": .string("/"), "target": Self.target(installation: installation, redirect: redirect, container: parsed.container)])])
        let created = try await client.post("/ingresses", body: .object(["hostname": .string(host), "projectId": .string(project), "paths": paths]))
        guard let id = created.string("id") else { throw KastellanError.provider("Mittwald: Antwort ohne Ingress-ID") }
        let item = try await client.get("/ingresses/\(id)")
        var sub = subdomain(item)
        if let own = item["ownership"], own.bool("verified") == false, let txt = own.string("txtRecord") {
            sub.extra["note"] = .string("Domain gehört nicht zum Projekt: TXT-Record \(txt) setzen und ingress verify-ownership ausführen (extra.verify_ownership bei subdomain_update).")
        }
        return sub
    }

    public func updateSubdomain(fqdn: String, targetPath: String?, redirect: String?, extra: Extra) async throws -> Subdomain {
        let item = try await ingress(named: fqdn)
        guard let id = item.string("id") else { throw KastellanError.notFound("Ingress \(fqdn) bei Mittwald") }
        if targetPath != nil || redirect != nil || extra["app_installation_id"] != nil {
            let parsed = Self.parseTargetPath(targetPath)
            let installation = extra["app_installation_id"]?.stringValue ?? parsed.installation
            var paths = item.array("paths")
            let target = Self.target(installation: installation, redirect: redirect, container: parsed.container)
            if let idx = paths.firstIndex(where: { $0.string("path") == "/" }) {
                paths[idx] = .object(["path": .string("/"), "target": target])
            } else {
                paths.append(.object(["path": .string("/"), "target": target]))
            }
            try await client.patch("/ingresses/\(id)/paths", body: .array(paths))
        }
        if extra["verify_ownership"]?.boolValue == true {
            try await client.post("/ingresses/\(id)/actions/verify-ownership")
        }
        if extra["acme"]?.boolValue == true {
            try await client.patch("/ingresses/\(id)/tls", body: .object(["acme": .bool(true)]))
        }
        return subdomain(try await client.get("/ingresses/\(id)"))
    }

    public func deleteSubdomain(fqdn: String) async throws {
        let item = try await ingress(named: fqdn)
        guard let id = item.string("id") else { throw KastellanError.notFound("Ingress \(fqdn) bei Mittwald") }
        if item.bool("isDefault") == true {
            throw KastellanError.invalidArgument("Mittwald: der Standard-Ingress \(fqdn) des Projekts lässt sich nicht löschen")
        }
        try await client.delete("/ingresses/\(id)")
    }

    /// Let's Encrypt anstoßen (Standard ohne extra), eigenes Zertifikat hochladen
    /// (extra.certificate + extra.private_key) oder ein vorhandenes zuweisen (extra.certificate_id).
    public func updateCertificate(hostname: String, forceHTTPS: Bool?, extra: Extra) async throws -> Certificate {
        let item = try await ingress(named: hostname)
        guard let id = item.string("id"), let project = item.string("projectId") else { throw KastellanError.notFound("Ingress \(hostname) bei Mittwald") }
        var certificateID = extra["certificate_id"]?.stringValue
        if let pem = extra["certificate"]?.stringValue, !pem.isEmpty {
            guard let key = extra["private_key"]?.stringValue, !key.isEmpty else {
                throw KastellanError.invalidArgument("Mittwald: eigenes Zertifikat braucht extra.private_key")
            }
            let request = try await client.post("/certificate-requests", body: .object(["projectId": .string(project), "certificate": .string(pem), "privateKey": .string(key)]))
            guard let requestID = request.string("id") else { throw KastellanError.provider("Mittwald: Antwort ohne Zertifikatsanfrage-ID") }
            // Die Anfrage liefert keine Zertifikats-ID; das Zertifikat trägt die Anfrage-ID.
            let certs = try await client.list("/certificates", query: [("projectId", project)])
            guard let cert = certs.first(where: { $0.string("certificateRequestId") == requestID }), let id = cert.string("id") else {
                var pending = Certificate(ref: ref(requestID), hostname: hostname, issuer: nil, validUntil: nil, autoRenew: false, forceHTTPS: nil, extra: ["certificate_request_id": .string(requestID)])
                pending.extra["note"] = .string("Zertifikatsanfrage \(requestID) angelegt; das Zertifikat ist noch nicht verfügbar. Später mit extra.certificate_id zuweisen.")
                return pending
            }
            certificateID = id
        }
        if let certificateID {
            try await client.patch("/ingresses/\(id)/tls", body: .object(["certificateId": .string(certificateID)]))
        } else {
            try await client.patch("/ingresses/\(id)/tls", body: .object(["acme": .bool(true)]))
            if extra["request_issuance"]?.boolValue != false {
                _ = try? await client.post("/ingresses/\(id)/actions/request-acme-certificate-issuance")
            }
        }
        let certs = try await client.list("/certificates", query: [("projectId", project), ("ingressId", id)])
        if let first = certs.first { return certificate(first) }
        let updated = try await client.get("/ingresses/\(id)")
        var cert = Certificate(ref: ref(id), hostname: hostname, issuer: certificateID == nil ? "Let's Encrypt (angefordert)" : nil, validUntil: nil,
                               autoRenew: certificateID == nil, forceHTTPS: nil, extra: ["tls": updated["tls"] ?? .null, "ingress_id": .string(id)])
        if forceHTTPS != nil { cert.extra["note"] = .string("Mittwald leitet HTTP immer auf HTTPS um; force_https hat keine eigene Einstellung.") }
        return cert
    }
}

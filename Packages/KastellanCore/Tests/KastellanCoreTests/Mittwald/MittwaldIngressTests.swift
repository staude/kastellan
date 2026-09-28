import Foundation
import Testing
@testable import KastellanCore

struct MittwaldIngressTests {
    static let project = "11111111-1111-4111-8111-111111111111"
    static let settings = ["project_id": project]
    static func ingress(id: String = "i-9", host: String = "neu.example.com", verified: Bool = true, isDefault: Bool = false, target: String = #"{"installationId":"a-1"}"#) -> String {
        let ownership = verified ? #"{"verified":true}"# : #"{"verified":false,"txtRecord":"mittwald-verify=abc"}"#
        return "{\"id\":\"\(id)\",\"hostname\":\"\(host)\",\"projectId\":\"\(project)\",\"isDefault\":\(isDefault),\"isDomain\":false,\"isEnabled\":true,\"ips\":{\"v4\":[],\"v6\":[]},\"ownership\":\(ownership),\"paths\":[{\"path\":\"/\",\"target\":\(target)}],\"tls\":{\"acme\":true,\"isCreated\":false}}"
    }

    @Test func createSubdomainUsesSingleAppInstallation() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.page([#"{"id":"a-1","appName":"WordPress"}"#], total: 1),
            MittwaldFixtures.json(#"{"id":"i-9"}"#, status: 201, headers: ["etag": "3"]),
            MittwaldFixtures.json(Self.ingress()),
        ], settings: Self.settings)
        let sub = try await adapter.createSubdomain(fqdn: "Neu.example.com", targetPath: nil, redirect: nil, extra: [:])
        #expect(sub.fqdn == "neu.example.com")
        #expect(sub.targetPath == "app:a-1")
        #expect(sub.extra["note"] == nil)
        let requests = await transport.requests
        #expect(requests[0].path == "/projects/\(Self.project)/app-installations")
        #expect(requests[1].method == "POST" && requests[1].path == "/ingresses")
        #expect(requests[1].body == .object(["hostname": .string("neu.example.com"), "projectId": .string(Self.project), "paths": .array([.object(["path": .string("/"), "target": .object(["installationId": .string("a-1")])])])]))
        #expect(requests[2].headers["if-event-reached"] == "3")
    }

    @Test func createSubdomainWithRedirectAndOwnershipNote() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.json(#"{"id":"i-9"}"#, status: 201),
            MittwaldFixtures.json(Self.ingress(host: "go.example.org", verified: false, target: #"{"url":"https://example.net/"}"#)),
        ], settings: Self.settings)
        let sub = try await adapter.createSubdomain(fqdn: "go.example.org", targetPath: nil, redirect: "https://example.net/", extra: [:])
        #expect(sub.redirect == "https://example.net/")
        #expect(sub.extra["note"]?.stringValue?.contains("mittwald-verify=abc") == true)
        let body = try #require(await transport.requests[0].body)
        #expect(body.array("paths").first?["target"] == .object(["url": .string("https://example.net/")]))
    }

    @Test func createSubdomainWithExplicitAppOrDefaultPage() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.json(#"{"id":"i-9"}"#, status: 201), MittwaldFixtures.json(Self.ingress()),
            MittwaldFixtures.json(#"{"id":"i-9"}"#, status: 201), MittwaldFixtures.json(Self.ingress(target: #"{"useDefaultPage":true}"#)),
        ], settings: Self.settings)
        _ = try await adapter.createSubdomain(fqdn: "a.example.com", targetPath: "app:a-7", redirect: nil, extra: [:])
        _ = try await adapter.createSubdomain(fqdn: "b.example.com", targetPath: "default-page", redirect: nil, extra: [:])
        let requests = await transport.requests
        #expect(requests[0].body?.array("paths").first?["target"] == .object(["installationId": .string("a-7")]))
        #expect(requests[2].body?.array("paths").first?["target"] == .object(["useDefaultPage": .bool(true)]))
    }

    @Test func updateSubdomainPatchesPathsVerifiesAndActivatesAcme() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.page([Self.ingress()], total: 1),
            MittwaldFixtures.empty(), MittwaldFixtures.json("{}"), MittwaldFixtures.json(#"{"acme":true,"isCreated":false}"#),
            MittwaldFixtures.json(Self.ingress(target: #"{"url":"https://example.net/"}"#)),
        ], settings: Self.settings)
        let sub = try await adapter.updateSubdomain(fqdn: "neu.example.com", targetPath: nil, redirect: "https://example.net/", extra: ["verify_ownership": .bool(true), "acme": .bool(true)])
        #expect(sub.redirect == "https://example.net/")
        let requests = await transport.requests
        #expect(requests[0].query["hostnameSubstring"] == "neu.example.com")
        #expect(requests[1].method == "PATCH" && requests[1].path == "/ingresses/i-9/paths")
        #expect(requests[1].body == .array([.object(["path": .string("/"), "target": .object(["url": .string("https://example.net/")])])]))
        #expect(requests[2].path == "/ingresses/i-9/actions/verify-ownership")
        #expect(requests[3].path == "/ingresses/i-9/tls" && requests[3].body == .object(["acme": .bool(true)]))
    }

    @Test func deleteSubdomainRefusesDefaultIngress() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.page([Self.ingress(isDefault: true)], total: 1),
            MittwaldFixtures.page([Self.ingress()], total: 1), MittwaldFixtures.empty(),
        ], settings: Self.settings)
        await #expect(throws: KastellanError.self) { try await adapter.deleteSubdomain(fqdn: "neu.example.com") }
        try await adapter.deleteSubdomain(fqdn: "neu.example.com")
        let requests = await transport.requests
        #expect(requests[2].method == "DELETE" && requests[2].path == "/ingresses/i-9")
    }

    @Test func updateCertificateActivatesAcmeAndReturnsCertificate() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.page([Self.ingress()], total: 1),
            MittwaldFixtures.json(#"{"acme":true,"isCreated":false}"#),
            MittwaldFixtures.empty(),
            MittwaldFixtures.page([#"{"id":"cert-1","commonName":"neu.example.com","issuer":"Let's Encrypt","certificateType":1,"validTo":"2026-12-01T00:00:00Z","isExpired":false,"projectId":"p"}"#], total: 1),
        ], settings: Self.settings)
        let cert = try await adapter.updateCertificate(hostname: "neu.example.com", forceHTTPS: nil, extra: [:])
        #expect(cert.hostname == "neu.example.com")
        #expect(cert.autoRenew == true)
        let requests = await transport.requests
        #expect(requests[1].path == "/ingresses/i-9/tls" && requests[1].body == .object(["acme": .bool(true)]))
        #expect(requests[2].path == "/ingresses/i-9/actions/request-acme-certificate-issuance")
        #expect(requests[3].query["ingressId"] == "i-9")
    }

    @Test func updateCertificateUploadsOwnCertificate() async throws {
        let (adapter, transport, _) = MittwaldFixtures.adapter([
            MittwaldFixtures.page([Self.ingress()], total: 1),
            MittwaldFixtures.json(#"{"id":"req-1","commonName":"neu.example.com"}"#, status: 201),
            MittwaldFixtures.page([#"{"id":"cert-9","commonName":"neu.example.com","certificateRequestId":"req-1","certificateType":2,"projectId":"p"}"#], total: 1),
            MittwaldFixtures.json("{}"),
            MittwaldFixtures.page([#"{"id":"cert-9","commonName":"neu.example.com","certificateRequestId":"req-1","certificateType":2,"projectId":"p"}"#], total: 1),
        ], settings: Self.settings)
        let cert = try await adapter.updateCertificate(hostname: "neu.example.com", forceHTTPS: true, extra: ["certificate": .string("-----BEGIN CERTIFICATE-----"), "private_key": .string("-----BEGIN PRIVATE KEY-----")])
        #expect(cert.ref.providerRef == "cert-9")
        #expect(cert.extra["certificateType"] == .string("external"))
        let requests = await transport.requests
        #expect(requests[1].method == "POST" && requests[1].path == "/certificate-requests")
        #expect(requests[1].body?.string("projectId") == Self.project)
        #expect(requests[3].path == "/ingresses/i-9/tls" && requests[3].body == .object(["certificateId": .string("cert-9")]))
    }

    @Test func targetHelpers() {
        #expect(MittwaldAdapter.target(installation: nil, redirect: nil, container: nil) == .object(["useDefaultPage": .bool(true)]))
        #expect(MittwaldAdapter.parseTargetPath("app:x").installation == "x")
        #expect(MittwaldAdapter.parseTargetPath("container:y").container == "y")
        #expect(MittwaldAdapter.capabilityMatrix.supports(Capability(.subdomain, .create)))
    }
}

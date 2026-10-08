import Foundation
import Testing
@testable import KastellanCore

struct NamecheapCertificateTests {
    @Test func emptyRealFixture() async throws {
        let (adapter, transport) = NamecheapFixtures.adapter([try NamecheapFixtures.ok("ssl-getlist")])
        #expect(try await adapter.listCertificates().isEmpty)
        #expect(await transport.requests.first?.command == "namecheap.ssl.getList")
    }

    @Test func listMapsCertificates() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([NamecheapFixtures.response("namecheap.ssl.getList", #"<SSLListResult><SSL CertificateID="52556" HostName="www.example.com" SSLType="PositiveSSL" PurchaseDate="10/10/2025" ExpireDate="10/10/2026" ActivationExpireDate="11/09/2025" IsExpiredYN="false" Status="ACTIVE" /><SSL CertificateID="52557" HostName="" SSLType="EssentialSSL" PurchaseDate="10/01/2026" ExpireDate="10/01/2027" IsExpiredYN="false" Status="NEWPURCHASE" /></SSLListResult><Paging><TotalItems>2</TotalItems><CurrentPage>1</CurrentPage><PageSize>100</PageSize></Paging>"#)])
        let certs = try await adapter.listCertificates()
        #expect(certs.count == 2)
        let active = try #require(certs.first { $0.hostname == "www.example.com" })
        #expect(active.issuer == "PositiveSSL")
        #expect(active.validUntil == NamecheapAdapter.date("10/10/2026"))
        #expect(active.extra["status"] == .string("active"))
        #expect(active.ref.providerRef == "52556")
        #expect(certs.contains { $0.hostname == "(nicht aktiviert)" })
    }

    @Test func updateIsUnsupportedAndMatrixIsReadOnly() async throws {
        let (adapter, _) = NamecheapFixtures.adapter([])
        await #expect(throws: KastellanError.self) { _ = try await adapter.updateCertificate(hostname: "example.com", forceHTTPS: true, extra: [:]) }
        #expect(NamecheapAdapter.capabilityMatrix.supports(Capability(.certificate, .list)))
        #expect(!NamecheapAdapter.capabilityMatrix.supports(Capability(.certificate, .update)))
    }
}

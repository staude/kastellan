import Foundation
import Testing
@testable import KastellanCore

struct AssignmentStoreTests {
    func store() -> AssignmentStore {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-assign-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return AssignmentStore(fileURL: d.appendingPathComponent("assignments.json"))
    }

    @Test func specificRulesWin() async throws {
        let s = store()
        try await s.upsert(Assignment(profileID: "ctx", domainPattern: "*", resource: nil, connectionID: "kas"))
        try await s.upsert(Assignment(profileID: "ctx", domainPattern: "example.com", resources: [.dnsRecord, .dnsZone], connectionID: "cloudflare"))
        try await s.upsert(Assignment(profileID: "ctx", domainPattern: "*.example.com", resource: nil, connectionID: "kas-sub"))
        #expect(try await s.resolve(profileID: "ctx", domain: "example.com", resource: .dnsRecord).map(\.connectionID) == ["cloudflare", "kas-sub", "kas"])
        #expect(try await s.resolve(profileID: "ctx", domain: "x@example.com", resource: .mailbox).first?.connectionID == "kas-sub")
        #expect(try await s.resolve(profileID: "ctx", domain: "fremd.de", resource: .mailbox).map(\.connectionID) == ["kas"])
        #expect(try await s.resolve(profileID: "anderer", domain: "example.com", resource: nil).isEmpty)
        #expect(try await s.resolve(profileID: "ctx", domain: "example.com", resource: .dnsZone).first?.connectionID == "cloudflare")
        #expect(try await s.resolve(profileID: "ctx", domain: "example.com", resource: .mailbox).first?.connectionID == "kas-sub")
        // Altes Format mit einzelnem resource-Feld bleibt lesbar
        let legacy = #"{"id":"l1","profile_id":"ctx","domain":"alt.de","resource":"mailbox","connection_id":"kas"}"#
        let a = try JSONCoding.decoder.decode(Assignment.self, from: Data(legacy.utf8))
        #expect(a.resources == [.mailbox])
        try await s.removeConnection("kas")
        #expect(try await s.list(profileID: "ctx").count == 2)
    }
}

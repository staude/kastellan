import Foundation
import Testing
@testable import KastellanCore

struct PolicyStoreTests {
    let example = """
    {
      "profile": "privat",
      "client": "claude-code",
      "connections": {
        "allinkl-beispiel": {
          "domains": ["example.com", "*.example.com", "firma.example"],
          "exclude": ["user@firma.example"],
          "permissions": {
            "domain": "read",
            "subdomain": "write",
            "dns_record": "write",
            "mailbox": "write",
            "mail_forward": "write",
            "dkim": "read",
            "subaccount": "none"
          },
          "scopes": { "record_types": ["A", "AAAA", "CNAME", "TXT", "CAA"] },
          "confirm_extra": ["mailbox:update"],
          "max_writes_per_hour": 30
        }
      }
    }
    """

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-policies-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func decodesConceptExample() throws {
        let cp = try JSONCoding.decoder.decode(ClientPolicy.self, from: Data(example.utf8))
        let p = try #require(cp.connections["allinkl-beispiel"])
        #expect(p.level(for: .mailbox) == .write)
        #expect(p.level(for: .subaccount) == .none)
        #expect(p.level(for: .cronJob) == .none)
        #expect(p.scopes.dnsRecordTypes.contains("TXT"))
        #expect(p.extraConfirmations == [Capability(.mailbox, .update)])
        #expect(p.maxWritesPerHour == 30)
        #expect(p.agentMayConfirm == false)
    }

    @Test func rejectsUnknownResource() {
        let bad = #"{"client":"x","connections":{"c":{"permissions":{"teleport":"write"}}}}"#
        #expect(throws: DecodingError.self) {
            try JSONCoding.decoder.decode(ClientPolicy.self, from: Data(bad.utf8))
        }
    }

    @Test func saveLoadRoundTrip() async throws {
        let store = PolicyStore(directory: tempDir())
        let cp = try JSONCoding.decoder.decode(ClientPolicy.self, from: Data(example.utf8))
        try await store.save(cp)
        #expect(try await store.all().map(\.client) == ["claude-code"])
        let loaded = try await store.load(profile: "Privat", client: "Claude Code")
        #expect(loaded == cp)
        var p = try await store.policy(profile: "privat", client: "claude-code", connectionID: "allinkl-beispiel")
        p.levels[.cronJob] = .read
        try await store.set(p, profile: "privat", client: "claude-code", connectionID: "allinkl-beispiel")
        #expect(try await store.policy(profile: "privat", client: "claude-code", connectionID: "allinkl-beispiel").level(for: .cronJob) == .read)
        #expect(try await store.policy(profile: "privat", client: "claude-code", connectionID: "unbekannt").level(for: .mailbox) == .none)
        #expect(try await store.policy(profile: "beruflich", client: "claude-code", connectionID: "allinkl-beispiel").level(for: .mailbox) == .none)
        try await store.removeConnection("allinkl-beispiel")
        #expect(try await store.load(profile: "privat", client: "claude-code").connections.isEmpty)
    }

    @Test func engineHonorsRecordTypeScopeAndProtectedTypes() throws {
        let cp = try JSONCoding.decoder.decode(ClientPolicy.self, from: Data(example.utf8))
        let p = cp.connections["allinkl-beispiel"]!
        let matrix = CapabilityMatrix(provider: "kas", capabilities: CapabilityMatrix.full(.dnsRecord).union(CapabilityMatrix.full(.mailbox)))
        let engine = PolicyEngine()
        #expect(engine.authorize(Capability(.dnsRecord, .create), policy: p, matrix: matrix, target: "example.com", recordType: "TXT") == .allowed)
        #expect(engine.authorize(Capability(.dnsRecord, .create), policy: p, matrix: matrix, target: "example.com", recordType: "SRV") == .outOfScope)
        #expect(engine.authorize(Capability(.dnsRecord, .create), policy: p, matrix: matrix, target: "example.com", recordType: "MX")
            == .deniedByPolicy(.write, required: .manage))
        var manage = p
        manage.levels[.dnsRecord] = .manage
        #expect(engine.authorize(Capability(.dnsRecord, .create), policy: manage, matrix: matrix, target: "example.com", recordType: "MX") == .requiresConfirmation)
        #expect(engine.authorize(Capability(.dnsRecord, .list), policy: p, matrix: matrix, target: "example.com", recordType: "MX") == .allowed)
        // confirm_extra aus der Datei
        #expect(engine.authorize(Capability(.mailbox, .update), policy: p, matrix: matrix, target: "x@example.com") == .requiresConfirmation)
    }
}

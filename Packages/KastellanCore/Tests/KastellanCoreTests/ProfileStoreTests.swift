import Foundation
import Testing
@testable import KastellanCore

struct ProfileStoreTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-ctx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func seedsDefaultsAndFindsBySlug() async throws {
        let store = ProfileStore(fileURL: tempDir().appendingPathComponent("profiles.json"))
        let all = try await store.list()
        #expect(all.map(\.name) == ["Privat", "Beruflich"])
        #expect(try await store.find(slug: "beruflich")?.name == "Beruflich")
        let neu = try await store.create(name: "Verein")
        #expect(neu.slug == "verein")
        await #expect(throws: KastellanError.self) { try await store.create(name: "verein") }
    }

    @Test func tokensOnlySeeConnectionsOfTheirContext() async throws {
        let dir = tempDir()
        let profiles = ProfileStore(fileURL: dir.appendingPathComponent("profiles.json"))
        let privat = try #require(try await profiles.find(slug: "privat"))
        let beruflich = try #require(try await profiles.find(slug: "beruflich"))

        let connections = ConnectionStore(fileURL: dir.appendingPathComponent("connections.json"))
        try await connections.upsert(Connection(profileID: privat.id, provider: "allinkl", label: "beispiel"))
        try await connections.upsert(Connection(profileID: beruflich.id, provider: "allinkl", label: "firma"))
        try await connections.upsert(Connection(profileID: beruflich.id, provider: "cloudflare", label: "firma-dns"))

        let tokens = TokenStore(fileURL: dir.appendingPathComponent("tokens.json"))
        let t = try await tokens.issue(client: "Claude Code", profileID: privat.id)
        let record = try #require(try await tokens.verify(t.token))
        let visible = try await connections.list(profileID: record.profileID)
        #expect(visible.map(\.label) == ["beispiel"])
        #expect(try await connections.list().count == 3)

        let json = String(decoding: try Data(contentsOf: dir.appendingPathComponent("connections.json")), as: UTF8.self)
        #expect(json.contains("\"profile_id\""))
    }
}

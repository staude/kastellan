import Foundation
import Testing
@testable import KastellanCore

struct PendingActionStoreTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-pending-\(UUID().uuidString)", isDirectory: true)
    }

    func sample() -> PendingAction {
        PendingAction(client: "claude-code", connectionID: "c1", capability: Capability(.mailbox, .delete),
                      target: "alt@example.com", parameters: ["address": .string("alt@example.com")],
                      preview: "Postfach alt@example.com löschen (47 MB belegt, keine Weiterleitungen)")
    }

    @Test func lifecycle() async throws {
        let store = PendingActionStore(directory: tempDir())
        let a = try await store.create(sample())
        #expect(try await store.list().map(\.id) == [a.id])
        let c = try await store.transition(id: a.id, to: .confirmed)
        #expect(c.decidedAt != nil)
        _ = try await store.transition(id: a.id, to: .executing)
        let d = try await store.transition(id: a.id, to: .done, result: .object(["deleted": .bool(true)]))
        #expect(d.status == .done)
        #expect(d.finishedAt != nil)
        #expect(try await store.list().isEmpty)
        #expect(try await store.list(includeFinal: true).count == 1)
    }

    @Test func invalidTransitions() async throws {
        let store = PendingActionStore(directory: tempDir())
        let a = try await store.create(sample())
        await #expect(throws: KastellanError.self) { try await store.transition(id: a.id, to: .done) }
        _ = try await store.transition(id: a.id, to: .cancelled)
        await #expect(throws: KastellanError.self) { try await store.transition(id: a.id, to: .confirmed) }
        await #expect(throws: KastellanError.self) { try await store.transition(id: "gibt-es-nicht", to: .confirmed) }
    }

    @Test func fileIsReadableByASecondInstance() async throws {
        let dir = tempDir()
        let a = try await PendingActionStore(directory: dir).create(sample())
        let other = PendingActionStore(directory: dir)
        let loaded = try #require(try await other.get(id: a.id))
        #expect(loaded.id == a.id)
        #expect(loaded.capability == a.capability)
        #expect(loaded.parameters == a.parameters)
        #expect(abs(loaded.createdAt.timeIntervalSince(a.createdAt)) < 1) // ISO-8601 ohne Sekundenbruchteile
        let json = String(decoding: try Data(contentsOf: dir.appendingPathComponent("\(a.id).json")), as: UTF8.self)
        #expect(json.contains("\"connection_id\""))
        #expect(json.contains("mailbox:delete") == false) // Capability wird als Objekt gespeichert
        #expect(json.contains("\"resource\" : \"mailbox\""))
    }

    @Test func purgeRemovesOnlyFinal() async throws {
        let store = PendingActionStore(directory: tempDir())
        let a = try await store.create(sample())
        _ = try await store.transition(id: a.id, to: .cancelled)
        _ = try await store.create(sample())
        #expect(try await store.purge(olderThan: -1) == 1)
        #expect(try await store.list(includeFinal: true).count == 1)
    }
}

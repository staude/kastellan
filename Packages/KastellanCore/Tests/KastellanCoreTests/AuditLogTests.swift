import Foundation
import Testing
@testable import KastellanCore

struct AuditLogTests {
    func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kastellan-audit-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test func appendAndFilter() throws {
        let log = AuditLog(fileURL: tempFile("audit.jsonl"))
        try log.append(AuditEntry(client: "claude-code", connectionID: "c1", capability: Capability(.mailbox, .list), outcome: .ok, providerCall: "get_mailaccounts", durationMS: 512))
        try log.append(AuditEntry(client: "claude-code", connectionID: "c1", capability: Capability(.mailbox, .create), target: "x@example.com", outcome: .ok, providerCall: "add_mailaccount"))
        try log.append(AuditEntry(client: "skript", connectionID: "c1", capability: Capability(.mailbox, .delete), target: "y@example.com", outcome: .pending, pendingActionID: "p1"))
        try log.append(AuditEntry(client: "claude-code", connectionID: "c2", capability: Capability(.dnsRecord, .create), outcome: .denied, message: "write nötig"))

        #expect(try log.entries().count == 4)
        #expect(try log.entries(AuditFilter(client: "skript")).first?.pendingActionID == "p1")
        #expect(try log.entries(AuditFilter(connectionID: "c2")).first?.outcome == .denied)
        #expect(try log.entries(AuditFilter(limit: 2)).map { $0.capability?.action } == [.delete, .create])
        #expect(try log.writeCount(client: "claude-code", connectionID: "c1", since: Date(timeIntervalSinceNow: -3600)) == 1)

        let raw = String(decoding: try Data(contentsOf: log.fileURL), as: UTF8.self)
        #expect(raw.split(separator: "\n").count == 4)
        #expect(raw.contains("\"connection_id\":\"c1\""))
        #expect(!raw.contains("\n\n"))
    }

    @Test func toleratesTruncatedLine() throws {
        let log = AuditLog(fileURL: tempFile("audit.jsonl"))
        try log.append(AuditEntry(client: "a", capability: Capability(.domain, .list), outcome: .ok))
        let handle = try FileHandle(forWritingTo: log.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"kaputt\":".utf8))
        try handle.close()
        #expect(try log.entries().count == 1)
    }

    @Test func healthLatestPerConnection() throws {
        let health = HealthLog(fileURL: tempFile("health.jsonl"))
        try health.append(HealthStatus(connectionID: "c1", ok: false, message: "Login fehlgeschlagen"))
        try health.append(HealthStatus(connectionID: "c1", ok: true, message: "ok"))
        try health.append(HealthStatus(connectionID: "c2", ok: true, message: "ok"))
        let latest = try health.latest()
        #expect(latest["c1"]?.ok == true)
        #expect(latest.count == 2)
    }
}

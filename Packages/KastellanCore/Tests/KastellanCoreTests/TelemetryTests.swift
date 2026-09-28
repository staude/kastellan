import Foundation
import Testing
@testable import KastellanCore

struct TelemetryTests {
    @Test func dsnParsing() {
        let dsn = Telemetry.DSN("https://a72bba9093ea458e81780d0b490356ed@telemetrie.staude.cc/1")
        #expect(dsn?.key == "a72bba9093ea458e81780d0b490356ed")
        #expect(dsn?.storeURL.absoluteString == "https://telemetrie.staude.cc/api/1/store/")
        #expect(Telemetry.DSN("https://telemetrie.staude.cc/1") == nil)
        #expect(Telemetry.DSN("kaputt") == nil)
    }

    @Test func eventShapeAndScrubbing() {
        let e = Telemetry.event(level: .error, message: nil, exceptionType: "KastellanError.provider",
                                exceptionValue: "Provider-Fehler: mail_password=geheim123 bei add_mailaccount",
                                component: "mcp", environment: "development", tags: ["provider": "allinkl"], extra: [:])
        #expect(e["platform"] as? String == "other")
        #expect(e["release"] as? String == "kastellan@\(KastellanCore.version)")
        let tags = e["tags"] as! [String: String]
        #expect(tags["component"] == "mcp")
        #expect(tags["provider"] == "allinkl")
        let values = (e["exception"] as! [String: Any])["values"] as! [[String: String]]
        #expect(values[0]["type"] == "KastellanError.provider")
        #expect(JSONSerialization.isValidJSONObject(e))
        #expect(Telemetry.scrub("password: hunter2 rest").contains("hunter2") == false)
        #expect(Telemetry.scrub("Token kastellan_claude-code_" + String(repeating: "a", count: 48)).contains("aaaa") == false)
        #expect(Telemetry.scrub("Postfach x@example.com fehlt") == "Postfach x@example.com fehlt")
    }

    @Test func breadcrumbsFromAudit() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-bc-\(UUID().uuidString).jsonl")
        let log = AuditLog(fileURL: file)
        let crash = Date()
        try log.append(AuditEntry(timestamp: crash.addingTimeInterval(-3000), client: "alt", tool: "domain_list", outcome: .ok))
        try log.append(AuditEntry(timestamp: crash.addingTimeInterval(-60), client: "claude-code", connectionID: "c1", tool: "mailbox_create", capability: Capability(.mailbox, .create), target: "x@example.com", outcome: .ok, durationMS: 800))
        try log.append(AuditEntry(timestamp: crash.addingTimeInterval(-10), client: "claude-code", tool: "dns_record_list", target: "example.com", outcome: .outOfScope, message: "außerhalb"))
        try log.append(AuditEntry(timestamp: crash.addingTimeInterval(600), client: "claude-code", tool: "später", outcome: .ok))
        let crumbs = Telemetry.breadcrumbs(from: log, until: crash)
        #expect(crumbs.map(\.message) == ["mailbox_create x@example.com", "dns_record_list example.com"])
        #expect(crumbs[0].level == .info)
        #expect(crumbs[1].level == .warning)
        #expect(crumbs[0].data["duration_ms"] == "800")
        #expect(crumbs[1].data["message"] == "außerhalb")
    }

    @Test func optInRules() {
        #expect(Telemetry.isOptedIn(environment: [:], fileSetting: nil) == false)
        #expect(Telemetry.isOptedIn(environment: [:], fileSetting: true) == true)
        #expect(Telemetry.isOptedIn(environment: [:], fileSetting: false) == false)
        #expect(Telemetry.isOptedIn(environment: ["KASTELLAN_TELEMETRY": "on"], fileSetting: nil) == true)
        #expect(Telemetry.isOptedIn(environment: ["KASTELLAN_TELEMETRY": "ON"], fileSetting: false) == false)
        #expect(Telemetry.isOptedIn(environment: ["KASTELLAN_SENTRY_DSN": "https://k@example.com/1"], fileSetting: nil) == true)
        #expect(Telemetry.isOptedIn(environment: ["KASTELLAN_SENTRY_DSN": "https://k@example.com/1", "KASTELLAN_TELEMETRY": "off"], fileSetting: true) == false)
    }

    @Test func disabledByEnvironmentDoesNotSend() async {
        // Ohne Netz: nur prüfen, dass capture ohne configure nichts tut und nicht wirft.
        let t = Telemetry()
        await t.capture(KastellanError.provider("x"))
        #expect(await t.isEnabled == false)
    }
}

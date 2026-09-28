import Foundation
import Testing
@testable import KastellanCore

struct CrashReporterTests {
    let sample = """
    {"app_name":"Kastellan","timestamp":"2026-09-07 09:17:14.00 +0200","app_version":"0.1.0","bug_type":"309","name":"Kastellan"}
    {"modelCode":"Mac16,5","osVersion":{"train":"macOS 26.6.2"},"asi":{"libswiftCore.dylib":["Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value"]},"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"termination":{"indicator":"Trace/BPT trap: 5"},"usedImages":[{"name":"Kastellan"},{"name":"Kastellan.debug.dylib"},{"name":"libswiftCore.dylib"}],"threads":[{"triggered":true,"frames":[{"imageIndex":2,"symbol":"_assertionFailure"},{"imageIndex":1,"symbol":"AppSettings.apply()","sourceFile":"AppSettings.swift"},{"imageIndex":1,"symbol":"AppSettings.init()","sourceFile":"AppSettings.swift","sourceLine":41}]}]}
    """

    @Test func parsesSignalAndFrames() {
        let r = CrashReporter.parse(sample, fileName: "Kastellan-2026-09-07-091714.ips")
        #expect(r.signal == "SIGTRAP")
        #expect(r.version == "0.1.0")
        #expect(r.type == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(r.value.contains("Unexpectedly found nil"))
        #expect(r.frames.count == 3)
        #expect(r.frames.last?.function == "_assertionFailure")      // auslösender Frame zuletzt
        #expect(r.frames.first?.line == 41)
        #expect(r.frames[1].inApp)
        #expect(r.device["model"] == "Mac16,5")
        #expect(r.occurredAt != nil)
    }

    @Test func findsLatestReportSinceMarker() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-reports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: dir.appendingPathComponent("Kastellan-2026-09-07-091714.ips"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("Other-2026-09-07-000000.ips"))
        let reporter = CrashReporter(component: "test", reportsDirectory: dir)
        #expect(reporter.latestReport(for: "Kastellan", since: Date(timeIntervalSinceNow: -60))?.signal == "SIGTRAP")
        #expect(reporter.latestReport(for: "Kastellan", since: Date(timeIntervalSinceNow: 600)) == nil)
        #expect(reporter.latestReport(for: "Nix", since: .distantPast) == nil)
    }
}

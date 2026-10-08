import Foundation
import Testing
@testable import KastellanCore

struct PublicIPv4Tests {
    @Test func parsesTraceResponse() async throws {
        let trace = "fl=123\nh=1.1.1.1\nip=203.0.113.7\nts=1790000000.1\nvisit_scheme=https\n"
        let ip = try await PublicIPv4.detect(fetch: { url in
            #expect(url == PublicIPv4.traceURL)
            return Data(trace.utf8)
        })
        #expect(ip == "203.0.113.7")
    }

    @Test func rejectsIPv6AndGarbage() async throws {
        #expect(PublicIPv4.parse("ip=2001:db8::1\n") == nil)
        #expect(PublicIPv4.parse("ip=300.1.1.1\n") == nil)
        #expect(PublicIPv4.parse("nothing") == nil)
        await #expect(throws: KastellanError.self) { _ = try await PublicIPv4.detect(fetch: { _ in Data("ip=::1".utf8) }) }
    }
}

import Testing
@testable import KastellanCore

struct PolicyEngineTests {
    let engine = PolicyEngine()
    let kas = CapabilityMatrix(provider: "allinkl", capabilities: [
        Capability(.mailbox, .list), Capability(.mailbox, .create), Capability(.mailbox, .delete),
        Capability(.dnsRecord, .create), Capability(.dkim, .get),
    ])
    let policy = Policy(
        levels: [.mailbox: .write, .dnsRecord: .write, .dkim: .read],
        domainPatterns: ["example.com", "*.firma.example"],
        excludedTargets: ["user@firma.example"]
    )

    @Test func readWithinWrite() {
        #expect(engine.authorize(Capability(.mailbox, .list), policy: policy, matrix: kas, target: "example.com") == .allowed)
    }

    @Test func createAllowedInScope() {
        #expect(engine.authorize(Capability(.mailbox, .create), policy: policy, matrix: kas, target: "telemetrie@example.com") == .allowed)
    }

    @Test func deleteNeedsManage() {
        #expect(engine.authorize(Capability(.mailbox, .delete), policy: policy, matrix: kas, target: "x@example.com")
            == .deniedByPolicy(.write, required: .manage))
    }

    @Test func deleteWithManageRequiresConfirmation() {
        var p = policy
        p.levels[.mailbox] = .manage
        #expect(engine.authorize(Capability(.mailbox, .delete), policy: p, matrix: kas, target: "x@example.com") == .requiresConfirmation)
    }

    @Test func unsupportedBeatsPolicy() {
        #expect(engine.authorize(Capability(.sshUser, .list), policy: policy, matrix: kas) == .unsupportedByProvider)
    }

    @Test func outOfScopeDomain() {
        #expect(engine.authorize(Capability(.mailbox, .create), policy: policy, matrix: kas, target: "x@example.net") == .outOfScope)
    }

    @Test func wildcardCoversSubdomainsAndExclusionWins() {
        #expect(engine.authorize(Capability(.mailbox, .create), policy: policy, matrix: kas, target: "dev@firma.example") == .allowed)
        #expect(engine.authorize(Capability(.mailbox, .create), policy: policy, matrix: kas, target: "user@firma.example") == .outOfScope)
    }

    @Test func starAllowsEverything() {
        var p = policy
        p.domainPatterns = ["*"]
        #expect(engine.authorize(Capability(.mailbox, .create), policy: p, matrix: kas, target: "x@irgendwo.de") == .allowed)
        #expect(PolicyEngine.matches("example.com", patterns: ["*"]))
        #expect(PolicyEngine.matches("example.com", patterns: ["*.example.com"]))
        #expect(!PolicyEngine.matches("example.net", patterns: ["*.example.com"]))
    }

    @Test func capabilityDescription() {
        #expect(Capability(.mailForward, .create).description == "mail_forward:create")
    }
}

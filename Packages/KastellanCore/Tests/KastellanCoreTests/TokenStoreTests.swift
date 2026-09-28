import Foundation
import Testing
@testable import KastellanCore

struct TokenStoreTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kastellan-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tokens.json")
    }

    @Test func issueVerifyRevoke() async throws {
        let store = TokenStore(fileURL: tempFile())
        let issued = try await store.issue(client: "Claude Code", profileID: "ctx-privat")
        #expect(issued.token.hasPrefix("kastellan_claude-code_"))
        #expect(issued.token.count == "kastellan_claude-code_".count + 48)
        #expect(issued.record.tokenHash != issued.token)

        let verified = try await store.verify(issued.token)
        #expect(verified?.id == issued.record.id)
        #expect(verified?.profileID == "ctx-privat")
        #expect(verified?.lastUsedAt != nil)
        #expect(try await store.verify("kastellan_claude-code_falsch") == nil)

        try await store.revoke(id: issued.record.id)
        #expect(try await store.verify(issued.token) == nil)
        #expect(try await store.list().count == 1)
    }

    @Test func persistsAcrossInstances() async throws {
        let file = tempFile()
        let token = try await TokenStore(fileURL: file).issue(client: "skript", profileID: "ctx").token
        let again = TokenStore(fileURL: file)
        #expect(try await again.verify(token) != nil)
    }

    @Test func rejectsEmptyClient() async throws {
        let store = TokenStore(fileURL: tempFile())
        await #expect(throws: KastellanError.self) { try await store.issue(client: "   ", profileID: "ctx") }
    }
}

struct MCPConfigWriterTests {
    @Test func installsWithoutTouchingOtherKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("claude.json")
        try Data(#"{"numStartups": 3, "mcpServers": {"torromail": {"command": "/x"}}}"#.utf8).write(to: file)

        let writer = MCPConfigWriter(executable: URL(fileURLWithPath: "/Applications/Kastellan.app/Contents/MacOS/kastellan-mcp"))
        let privat = KastellanProfile(name: "Privat")
        let beruflich = KastellanProfile(name: "Beruflich")
        try writer.install(token: "kastellan_test_abc", target: .claudeCode, profile: privat, into: file)
        try writer.install(token: "kastellan_test_def", target: .claudeCode, profile: beruflich, into: file)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        #expect(root["numStartups"] as? Int == 3)
        let servers = root["mcpServers"] as! [String: Any]
        #expect(servers["torromail"] != nil)
        let k = servers["kastellan-privat"] as! [String: Any]
        #expect(k["type"] as? String == "stdio")
        #expect((k["env"] as! [String: String])["KASTELLAN_TOKEN"] == "kastellan_test_abc")
        #expect((servers["kastellan-beruflich"] as! [String: Any])["env"] as? [String: String] == ["KASTELLAN_TOKEN": "kastellan_test_def"])
        #expect(writer.isInstalled(target: .claudeCode, profile: privat, in: file))

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }
        #expect(backups.count == 2)

        try writer.uninstall(target: .claudeCode, profile: privat, from: file)
        #expect(!writer.isInstalled(target: .claudeCode, profile: privat, in: file))
        #expect(writer.isInstalled(target: .claudeCode, profile: beruflich, in: file))
    }

    @Test func desktopEntryHasNoTypeField() {
        let writer = MCPConfigWriter(executable: URL(fileURLWithPath: "/tmp/kastellan-mcp"))
        let e = writer.entry(token: "t", target: .claudeDesktop)
        #expect(e["type"] == nil)
        #expect(writer.snippet(token: "t", target: .claudeDesktop, profile: KastellanProfile(name: "Privat")).contains("\"kastellan-privat\""))
    }
}

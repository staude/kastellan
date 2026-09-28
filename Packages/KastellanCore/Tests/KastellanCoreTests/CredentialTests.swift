import Foundation
import Testing
@testable import KastellanCore

/// Stub für bw/op: antwortet je nach Argumenten mit vorbereiteten Ausgaben und zeichnet Aufrufe auf.
actor StubCLI: CLIRunner {
    var calls: [(String, [String], [String: String], String?)] = []
    var responses: [String: CLIResult] = [:]

    func on(_ key: String, _ stdout: String, status: Int32 = 0, stderr: String = "") {
        responses[key] = CLIResult(status: status, stdout: stdout, stderr: stderr)
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String], stdin: String?) async throws -> CLIResult {
        calls.append((executable, arguments, environment, stdin))
        let key = arguments.prefix(2).joined(separator: " ")
        return responses[key] ?? responses[arguments.first ?? ""] ?? CLIResult(status: 1, stdout: "", stderr: "unbekannt: \(arguments)")
    }
}

struct CredentialTests {
    let record = CredentialRecord(title: CredentialRecord.title(for: .mailbox, identifier: "info@example.com", connectionLabel: "All-Inkl privat"),
                                  username: "info@example.com", password: "Pw-123", host: "w00abcde.kasserver.com", scheme: "imaps", port: 993,
                                  resource: .mailbox, identifier: "info@example.com", connectionID: "c1", connectionLabel: "All-Inkl privat", profileID: "p1")

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("kastellan-cred-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func recordShape() {
        #expect(record.title == "Postfach info@example.com (All-Inkl privat)")
        #expect(record.url == "imaps://w00abcde.kasserver.com:993")
        #expect(record.fullNotes.contains("kastellan.resource=mailbox/info@example.com"))
        #expect(record.fullNotes.contains("kastellan.connection=All-Inkl privat (c1)"))
        var noHost = record; noHost.host = nil
        #expect(noHost.url == nil)
    }

    @Test func bitwardenItemJSON() throws {
        let personal = BitwardenSink.itemJSON(record, target: CredentialTarget(folderID: "f1", folderName: "Hosting"))
        #expect(personal["type"] as? Int == 1)
        #expect(personal["folderId"] as? String == "f1")
        #expect(personal["organizationId"] is NSNull)
        let login = personal["login"] as! [String: Any]
        #expect(login["username"] as? String == "info@example.com")
        #expect((login["uris"] as! [[String: Any]]).first?["uri"] as? String == "imaps://w00abcde.kasserver.com:993")
        #expect(JSONSerialization.isValidJSONObject(personal))

        let org = BitwardenSink.itemJSON(record, target: CredentialTarget(folderID: "f1", organizationID: "o1", collectionIDs: ["col1"]))
        #expect(org["organizationId"] as? String == "o1")
        #expect(org["collectionIds"] as? [String] == ["col1"])
        #expect(org["folderId"] is NSNull)
    }

    @Test func bitwardenSinkViaStub() async throws {
        let cli = StubCLI()
        await cli.on("--version", "2025.9.0\n")
        await cli.on("status", #"{"serverUrl":null,"lastSync":null,"userEmail":"user@example.com","status":"locked"}"#)
        await cli.on("unlock --passwordenv", "SESSIONKEY\n")
        await cli.on("list folders", #"[{"id":null,"name":"Kein Ordner"},{"id":"f1","name":"Hosting"}]"#)
        await cli.on("list organizations", #"[{"id":"o1","name":"Verein","status":2,"type":0,"enabled":true}]"#)
        await cli.on("create item", #"{"id":"item-1","name":"x"}"#)

        let locked = BitwardenSink(executable: "/bin/echo", runner: cli)
        let st = await locked.status()
        #expect(st.state == "locked" && st.userEmail == "user@example.com" && st.version == "2025.9.0")
        await #expect(throws: KastellanError.self) { _ = try await locked.store(record, target: CredentialTarget()) }

        let session = try await locked.unlock(masterPassword: "geheim")
        #expect(session == "SESSIONKEY")
        let unlockCall = await cli.calls.first { $0.1.first == "unlock" }!
        #expect(unlockCall.2["KASTELLAN_BW_PASSWORD"] == "geheim")
        #expect(!unlockCall.1.contains("geheim"))

        let sink = BitwardenSink(executable: "/bin/echo", session: session, runner: cli)
        #expect(try await sink.folders().map(\.name) == ["Kein Ordner", "Hosting"])
        #expect(try await sink.organizations().first?.name == "Verein")
        let where_ = try await sink.store(record, target: CredentialTarget(folderID: "f1", folderName: "Hosting"))
        #expect(where_.contains("Ordner Hosting") && where_.contains("item-1"))
        let create = await cli.calls.last!
        #expect(create.1[0] == "create" && create.2["BW_SESSION"] == "SESSIONKEY")
        let decoded = try JSONSerialization.jsonObject(with: Data(base64Encoded: create.1[2])!) as! [String: Any]
        #expect((decoded["login"] as! [String: Any])["password"] as? String == "Pw-123")
    }

    @Test func handoffStoresPasswordOnlyInSecrets() async throws {
        let secrets = InMemorySecretProvider()
        let store = CredentialHandoffStore(directory: tempDir(), secrets: secrets)
        let h = try await store.create(record, kind: .bitwarden, target: CredentialTarget(folderName: "Hosting"))
        #expect(h.record.password.isEmpty)
        let listed = try await store.list()
        #expect(listed.count == 1 && listed[0].kind == .bitwarden)
        let full = try await store.record(for: h)
        #expect(full.password == "Pw-123")
        try await store.remove(h)
        #expect(try await store.list().isEmpty)
        #expect(try await secrets.secret(connectionID: "kastellan", key: CredentialHandoff.secretKey(h.id)) == nil)
    }

    @Test func delivererModes() async throws {
        let dir = tempDir()
        let secrets = InMemorySecretProvider()
        let settings = CredentialSettingsStore(fileURL: dir.appendingPathComponent("credentials.json"))
        let handoffs = CredentialHandoffStore(directory: dir.appendingPathComponent("handoff"), secrets: secrets)
        let deliverer = CredentialDeliverer(settings: settings, handoffs: handoffs, keychain: KeychainCredentialSink(trustedPaths: []))

        try await settings.set(CredentialDeliveryConfig(kind: .resultOnly), profileID: "p1")
        #expect(await deliverer.deliver(record) == .resultOnly)
        let fields = CredentialDeliverer.resultFields(outcome: .resultOnly, password: "Pw-123", reveal: false)
        #expect(fields["password"] == .string("Pw-123"))

        try await settings.set(CredentialDeliveryConfig(kind: .bitwarden, target: CredentialTarget(folderName: "Hosting")), profileID: "p1")
        guard case .handedOff(let text) = await deliverer.deliver(record) else { Issue.record("erwartet handedOff"); return }
        #expect(text.contains("Bitwarden") && text.contains("Ordner Hosting"))
        #expect(try await handoffs.list().count == 1)
        let hidden = CredentialDeliverer.resultFields(outcome: .handedOff(text), password: "Pw-123", reveal: false)
        #expect(hidden["password"] == .string("wird abgelegt"))
        let shown = CredentialDeliverer.resultFields(outcome: .handedOff(text), password: "Pw-123", reveal: true)
        #expect(shown["password"] == .string("Pw-123"))

        // Direkter Tresor (App, entsperrt): kein Handoff
        let cli = StubCLI(); await cli.on("create item", #"{"id":"i2"}"#)
        let direct = CredentialDeliverer(settings: settings, handoffs: handoffs, keychain: KeychainCredentialSink(trustedPaths: []),
                                         directSinks: [.bitwarden: BitwardenSink(executable: "/bin/echo", session: "S", runner: cli)])
        guard case .stored(let where_) = await direct.deliver(record) else { Issue.record("erwartet stored"); return }
        #expect(where_.contains("Bitwarden"))
        #expect(try await handoffs.list().count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KASTELLAN_SKIP_KEYCHAIN_TESTS"] == nil))
    func keychainInternetPassword() async throws {
        let sink = KeychainCredentialSink(trustedPaths: [])
        var r = record
        r.host = "kastellan-test-\(UUID().uuidString.prefix(8)).example"
        let where_ = try await sink.store(r, target: CredentialTarget())
        #expect(where_.contains(r.host!))
        // Aufräumen
        let q: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: r.host!, kSecAttrAccount as String: r.username]
        #expect(SecItemDelete(q as CFDictionary) == errSecSuccess)
    }
}

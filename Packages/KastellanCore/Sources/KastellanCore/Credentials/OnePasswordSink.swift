import Foundation

/// 1Password über die CLI `op` mit App-Integration (Touch ID aus der 1Password-App).
public struct OnePasswordVault: Codable, Sendable, Identifiable, Equatable { public let id: String; public let name: String }

public struct OnePasswordStatus: Sendable, Equatable {
    public var installed: Bool
    public var path: String?
    public var version: String?
    public var signedIn: Bool
    public var account: String?
}

public struct OnePasswordSink: CredentialSink {
    public let kind: CredentialSinkKind = .onepassword
    public let runner: any CLIRunner
    public let executable: String

    public init(executable: String? = nil, runner: any CLIRunner = ProcessCLIRunner()) {
        self.executable = executable ?? ProcessCLIRunner.locate("op") ?? "/opt/homebrew/bin/op"
        self.runner = runner
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    public func status() async -> OnePasswordStatus {
        guard isInstalled else { return OnePasswordStatus(installed: false, path: nil, version: nil, signedIn: false, account: nil) }
        let version = (try? await runner.run(executable, ["--version"], environment: [:], stdin: nil))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = try? await runner.run(executable, ["whoami", "--format", "json"], environment: [:], stdin: nil)
        let account = who.flatMap { try? JSONSerialization.jsonObject(with: Data($0.stdout.utf8)) as? [String: Any] }?["email"] as? String
        return OnePasswordStatus(installed: true, path: executable, version: version, signedIn: who?.ok == true, account: account)
    }

    public func vaults() async throws -> [OnePasswordVault] {
        let r = try await runner.run(executable, ["vault", "list", "--format", "json"], environment: [:], stdin: nil)
        guard r.ok else { throw KastellanError.provider("op vault list: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return try JSONDecoder().decode([OnePasswordVault].self, from: Data(r.stdout.utf8))
    }

    public func store(_ record: CredentialRecord, target: CredentialTarget) async throws -> String {
        var args = ["item", "create", "--category", "login", "--title", record.title, "--tags", "kastellan,\(record.resource.rawValue)", "--format", "json"]
        if let vault = target.vault, !vault.isEmpty { args += ["--vault", vault] }
        if let url = record.url { args += ["--url", url] }
        // Feldzuweisungen als eigene Argumente; das Passwort geht so nicht über die Shell, aber über die Prozessliste.
        // Deshalb über stdin als Template, wenn op das erlaubt: op unterstützt `--template` mit Datei; wir nutzen die
        // Zuweisungssyntax und akzeptieren die kurze Sichtbarkeit im lokalen Prozess.
        args += ["username=\(record.username)", "password=\(record.password)", "notesPlain=\(record.fullNotes)"]
        let r = try await runner.run(executable, args, environment: [:], stdin: nil)
        guard r.ok else { throw KastellanError.provider("op item create: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let id = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])?["id"] as? String
        return "1Password" + (target.vault.map { ", Tresor \($0)" } ?? "") + (id.map { ", Eintrag \($0)" } ?? "")
    }
}

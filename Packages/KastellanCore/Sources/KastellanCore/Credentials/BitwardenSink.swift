import Foundation

/// Bitwarden über die CLI `bw`. Entsperren liefert einen Session-Schlüssel, der nur im Speicher der App lebt.
public struct BitwardenStatus: Sendable, Equatable {
    public var installed: Bool
    public var path: String?
    public var version: String?
    public var serverURL: String?
    public var userEmail: String?
    /// unauthenticated, locked, unlocked
    public var state: String
}

public struct BitwardenFolder: Codable, Sendable, Identifiable, Equatable { public let id: String?; public let name: String }
public struct BitwardenOrganization: Codable, Sendable, Identifiable, Equatable { public let id: String; public let name: String }
public struct BitwardenCollection: Codable, Sendable, Identifiable, Equatable { public let id: String; public let name: String; public let organizationId: String? }

public struct BitwardenSink: CredentialSink {
    public let kind: CredentialSinkKind = .bitwarden
    public let runner: any CLIRunner
    public let executable: String
    /// Session-Schlüssel aus `bw unlock --raw`.
    public let session: String?

    public init(executable: String? = nil, session: String? = nil, runner: any CLIRunner = ProcessCLIRunner()) {
        self.executable = executable ?? ProcessCLIRunner.locate("bw") ?? "/opt/homebrew/bin/bw"
        self.session = session
        self.runner = runner
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    private var env: [String: String] {
        var e = ["BW_NOINTERACTION": "true"]
        if let session { e["BW_SESSION"] = session }
        return e
    }

    public func status() async -> BitwardenStatus {
        guard isInstalled else { return BitwardenStatus(installed: false, path: nil, version: nil, serverURL: nil, userEmail: nil, state: "nicht installiert") }
        let version = (try? await runner.run(executable, ["--version"], environment: env, stdin: nil))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = try? await runner.run(executable, ["status"], environment: env, stdin: nil),
              let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] else {
            return BitwardenStatus(installed: true, path: executable, version: version, serverURL: nil, userEmail: nil, state: "unbekannt")
        }
        return BitwardenStatus(installed: true, path: executable, version: version, serverURL: obj["serverUrl"] as? String,
                               userEmail: obj["userEmail"] as? String, state: (obj["status"] as? String) ?? "unbekannt")
    }

    /// Entsperrt mit dem Master-Passwort; das Passwort geht nur über die Umgebung an `bw`, nie in Argumente.
    public func unlock(masterPassword: String) async throws -> String {
        let r = try await runner.run(executable, ["unlock", "--passwordenv", "KASTELLAN_BW_PASSWORD", "--raw"],
                                     environment: ["KASTELLAN_BW_PASSWORD": masterPassword, "BW_NOINTERACTION": "true"], stdin: nil)
        let token = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !token.isEmpty else {
            throw KastellanError.unauthorized("Bitwarden entsperren fehlgeschlagen: \(Self.clean(r.stderr))")
        }
        return token
    }

    public func lock() async {
        _ = try? await runner.run(executable, ["lock"], environment: env, stdin: nil)
    }

    public func sync() async {
        _ = try? await runner.run(executable, ["sync"], environment: env, stdin: nil)
    }

    public func folders() async throws -> [BitwardenFolder] {
        try await list("folders")
    }

    public func organizations() async throws -> [BitwardenOrganization] {
        try await list("organizations")
    }

    public func collections(organizationID: String) async throws -> [BitwardenCollection] {
        try await list("org-collections", extra: ["--organizationid", organizationID])
    }

    private func list<T: Decodable>(_ what: String, extra: [String] = []) async throws -> [T] {
        let r = try await runner.run(executable, ["list", what] + extra, environment: env, stdin: nil)
        guard r.ok else { throw KastellanError.provider("bw list \(what): \(Self.clean(r.stderr))") }
        return try JSONDecoder().decode([T].self, from: Data(r.stdout.utf8))
    }

    /// Login-Eintrag anlegen: `bw create item` mit Base64-kodiertem JSON.
    public func store(_ record: CredentialRecord, target: CredentialTarget) async throws -> String {
        guard session != nil else { throw KastellanError.unauthorized("Bitwarden ist gesperrt") }
        let item = Self.itemJSON(record, target: target)
        let data = try JSONSerialization.data(withJSONObject: item)
        let r = try await runner.run(executable, ["create", "item", data.base64EncodedString()], environment: env, stdin: nil)
        guard r.ok else { throw KastellanError.provider("bw create item: \(Self.clean(r.stderr))") }
        let id = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])?["id"] as? String
        var where_ = target.description
        if where_.isEmpty { where_ = "persönlicher Tresor" }
        return "Bitwarden, \(where_)" + (id.map { ", Eintrag \($0)" } ?? "")
    }

    /// Bitwarden-Item (type 1 = Login). Organisationseinträge brauchen collectionIds, persönliche folderId.
    static func itemJSON(_ record: CredentialRecord, target: CredentialTarget) -> [String: Any] {
        var login: [String: Any] = ["username": record.username, "password": record.password, "totp": NSNull()]
        if let url = record.url { login["uris"] = [["match": NSNull(), "uri": url]] } else { login["uris"] = [] }
        var item: [String: Any] = [
            "type": 1, "name": record.title, "notes": record.fullNotes, "favorite": false, "fields": [],
            "login": login, "reprompt": 0, "secureNote": NSNull(), "card": NSNull(), "identity": NSNull(),
            "organizationId": NSNull(), "collectionIds": NSNull(), "folderId": NSNull(),
        ]
        if let org = target.organizationID, !org.isEmpty {
            item["organizationId"] = org
            item["collectionIds"] = target.collectionIDs
        } else if let folder = target.folderID, !folder.isEmpty {
            item["folderId"] = folder
        }
        return item
    }

    static func clean(_ stderr: String) -> String {
        let t = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "unbekannter Fehler" : t.split(separator: "\n").first.map(String.init) ?? t
    }
}

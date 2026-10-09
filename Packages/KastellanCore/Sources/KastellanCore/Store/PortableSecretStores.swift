import Foundation
#if os(Windows)
import WinSDK
#endif

#if !canImport(Security) && !os(Windows)
/// Secrets im Secret Service des Desktops (GNOME Keyring, KWallet) über `secret-tool` aus libsecret,
/// wie bei TorroMail. Attribute `service=kastellan`, `account=<connection_id>/<key>`.
public struct SecretToolSecretStore: ManagedSecretStore, Sendable {
    public let service: String
    public var displayName: String { "Secret Service (secret-tool)" }

    public init(service: String = "kastellan") { self.service = service }

    public func secret(connectionID: String, key: String) async throws -> String? {
        let result = try run(["lookup", "service", service, "account", Self.account(connectionID, key)])
        guard result.status == 0 else { return nil }
        let value = result.output.trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    public func set(connectionID: String, key: String, value: String) async throws {
        let account = Self.account(connectionID, key)
        let result = try run(["store", "--label=Kastellan \(account)", "service", service, "account", account], input: value)
        guard result.status == 0 else { throw KastellanError.internal("secret-tool store: \(result.error)") }
    }

    public func delete(connectionID: String, key: String) async throws {
        _ = try run(["clear", "service", service, "account", Self.account(connectionID, key)])
    }

    public func keys(connectionID: String) throws -> [String] {
        let result = try run(["search", "--all", "--unlock", "service", service])
        let prefix = "attribute.account = \(connectionID)/"
        return (result.output + "\n" + result.error).split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix(prefix) ? String(l.dropFirst(prefix.count)) : nil
        }.sorted()
    }

    public func deleteAll(connectionID: String) throws {
        for key in try keys(connectionID: connectionID) {
            _ = try run(["clear", "service", service, "account", Self.account(connectionID, key)])
        }
    }

    static func account(_ connectionID: String, _ key: String) -> String { "\(connectionID)/\(key)" }

    private func run(_ arguments: [String], input: String? = nil) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["secret-tool"] + arguments
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out; process.standardError = err; process.standardInput = inp
        do { try process.run() } catch {
            throw KastellanError.internal("secret-tool nicht gefunden. Bitte libsecret-tools (Debian/Ubuntu) bzw. libsecret installieren.")
        }
        if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
        try? inp.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 127 {
            throw KastellanError.internal("secret-tool nicht gefunden. Bitte libsecret-tools (Debian/Ubuntu) bzw. libsecret installieren.")
        }
        return (process.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

/// Ohne Schlüsselbund der Plattform: Zugänge landen als Eintrag im Secret Service.
public struct KeychainCredentialSink: CredentialSink {
    public let kind: CredentialSinkKind = .keychain
    public init(trustedPaths: [String]? = nil) {}

    public func store(_ record: CredentialRecord, target: CredentialTarget) async throws -> String {
        let key = "credential/\(record.username)@\(record.host ?? record.connectionLabel)"
        try await makePlatformSecretStore().set(connectionID: record.connectionID, key: key, value: record.password)
        return "\(makePlatformSecretStore().displayName), \(key)"
    }
}
#endif

#if os(Windows)
/// Secrets in der Windows-Anmeldeinformationsverwaltung als generische Anmeldeinformation,
/// Zielname `Kastellan:<connection_id>/<key>`.
public struct WindowsCredentialSecretStore: ManagedSecretStore, Sendable {
    public var displayName: String { "Windows-Anmeldeinformationsverwaltung" }
    public init() {}

    static func target(_ connectionID: String, _ key: String) -> String { "Kastellan:\(connectionID)/\(key)" }

    public func secret(connectionID: String, key: String) async throws -> String? {
        var pointer: PCREDENTIALW?
        let ok = Self.target(connectionID, key).withCString(encodedAs: UTF16.self) { CredReadW($0, DWORD(CRED_TYPE_GENERIC), 0, &pointer) }
        guard ok, let cred = pointer else { return nil }
        defer { CredFree(cred) }
        let size = Int(cred.pointee.CredentialBlobSize)
        guard size > 0, let blob = cred.pointee.CredentialBlob else { return nil }
        return String(decoding: UnsafeBufferPointer(start: blob, count: size), as: UTF8.self)
    }

    public func set(connectionID: String, key: String, value: String) async throws {
        var bytes = Array(value.utf8)
        let target = Array(Self.target(connectionID, key).utf16) + [0]
        let user = Array("kastellan".utf16) + [0]
        let ok = target.withUnsafeBufferPointer { t in
            user.withUnsafeBufferPointer { u in
                bytes.withUnsafeMutableBufferPointer { b -> Bool in
                    var cred = CREDENTIALW()
                    cred.Type = DWORD(CRED_TYPE_GENERIC)
                    cred.TargetName = UnsafeMutablePointer(mutating: t.baseAddress)
                    cred.UserName = UnsafeMutablePointer(mutating: u.baseAddress)
                    cred.CredentialBlobSize = DWORD(b.count)
                    cred.CredentialBlob = b.baseAddress
                    cred.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                    return CredWriteW(&cred, 0)
                }
            }
        }
        guard ok else { throw KastellanError.internal("Anmeldeinformationsverwaltung: Speichern fehlgeschlagen (\(GetLastError()))") }
    }

    public func delete(connectionID: String, key: String) async throws {
        _ = Self.target(connectionID, key).withCString(encodedAs: UTF16.self) { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
    }

    public func keys(connectionID: String) throws -> [String] {
        var count: DWORD = 0
        var list: UnsafeMutablePointer<PCREDENTIALW?>?
        let prefix = "Kastellan:\(connectionID)/"
        let ok = (prefix + "*").withCString(encodedAs: UTF16.self) { CredEnumerateW($0, 0, &count, &list) }
        guard ok, let list else { return [] }
        defer { CredFree(list) }
        var keys: [String] = []
        for i in 0..<Int(count) {
            guard let cred = list[i], let name = cred.pointee.TargetName else { continue }
            let target = String(decodingCString: name, as: UTF16.self)
            if target.hasPrefix(prefix) { keys.append(String(target.dropFirst(prefix.count))) }
        }
        return keys.sorted()
    }

    public func deleteAll(connectionID: String) throws {
        for key in try keys(connectionID: connectionID) {
            _ = Self.target(connectionID, key).withCString(encodedAs: UTF16.self) { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
        }
    }
}

/// Zugänge als generische Anmeldeinformation in der Windows-Anmeldeinformationsverwaltung.
public struct KeychainCredentialSink: CredentialSink {
    public let kind: CredentialSinkKind = .keychain
    public init(trustedPaths: [String]? = nil) {}

    public func store(_ record: CredentialRecord, target: CredentialTarget) async throws -> String {
        let key = "credential/\(record.username)@\(record.host ?? record.connectionLabel)"
        try await WindowsCredentialSecretStore().set(connectionID: record.connectionID, key: key, value: record.password)
        return "Windows-Anmeldeinformationsverwaltung, Kastellan:\(record.connectionID)/\(key)"
    }
}
#endif

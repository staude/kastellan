import Foundation
#if canImport(Security)
import Security

/// Zugänge als Internet-Passwort im Login-Schlüsselbund: Server, Benutzername, Protokoll, Port, Label,
/// Kommentar mit Kastellan-Metadaten. Sichtbar in der Schlüsselbundverwaltung als „Internetkennwort“.
public struct KeychainCredentialSink: CredentialSink {
    public let kind: CredentialSinkKind = .keychain
    public let trustedPaths: [String]

    public init(trustedPaths: [String]? = nil) {
        self.trustedPaths = trustedPaths ?? KeychainSecretStore.defaultTrustedPaths()
    }

    public func store(_ record: CredentialRecord, target: CredentialTarget) async throws -> String {
        let server = record.host ?? record.connectionLabel
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: record.username,
            kSecAttrProtocol as String: Self.protocolValue(record.scheme),
        ]
        if let port = record.port { query[kSecAttrPort as String] = port }
        // Vorhandenen Eintrag ersetzen, damit die Zugriffsliste aktuell ist.
        _ = SecItemDelete(query as CFDictionary)
        query[kSecAttrLabel as String] = record.title
        query[kSecAttrComment as String] = record.fullNotes
        query[kSecValueData as String] = Data(record.password.utf8)
        if let access = try makeAccess(label: record.title) { query[kSecAttrAccess as String] = access }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw KastellanError.internal("Schlüsselbund speichern: \(text)")
        }
        return "Schlüsselbund, Internet-Passwort \(record.username) bei \(server)"
    }

    static func protocolValue(_ scheme: String) -> CFString {
        switch scheme.lowercased() {
        case "imaps": kSecAttrProtocolIMAPS
        case "imap": kSecAttrProtocolIMAP
        case "smtps", "smtp": kSecAttrProtocolSMTP
        case "ftp": kSecAttrProtocolFTP
        case "ftps": kSecAttrProtocolFTPS
        case "sftp", "ssh": kSecAttrProtocolSSH
        case "http": kSecAttrProtocolHTTP
        default: kSecAttrProtocolHTTPS
        }
    }

    private func makeAccess(label: String) throws -> SecAccess? {
        guard !trustedPaths.isEmpty else { return nil }
        var apps: [SecTrustedApplication] = []
        for path in trustedPaths {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        let status = SecAccessCreate(label as CFString, apps as CFArray, &access)
        guard status == errSecSuccess else { throw KastellanError.internal("Zugriffsliste: OSStatus \(status)") }
        return access
    }
}
#endif

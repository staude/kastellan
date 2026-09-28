import Foundation
import Security

/// Secrets im macOS-Login-Schlüsselbund. Service `kastellan`, Account `<connection_id>/<key>`.
///
/// App und kastellan-mcp teilen die Einträge über die Zugriffsliste (ACL) des Eintrags: beim Anlegen
/// werden beide Programme als vertrauenswürdig eingetragen. Keychain-Access-Groups scheiden aus, weil das
/// eingebettete Kommandozeilen-Binary kein Provisioning-Profil hat und das System es mit diesem
/// Entitlement sofort beendet.
public struct KeychainSecretStore: SecretStore, Sendable {
    public let service: String
    /// Programme, die Einträge lesen dürfen. Standard: die laufende App und das eingebettete kastellan-mcp.
    public let trustedPaths: [String]

    public init(service: String = "kastellan", trustedPaths: [String]? = nil) {
        self.service = service
        self.trustedPaths = trustedPaths ?? Self.defaultTrustedPaths()
    }

    /// Kastellan.app/Contents/MacOS/Kastellan und .../kastellan-mcp, egal welches von beiden gerade läuft.
    static func defaultTrustedPaths() -> [String] {
        guard let own = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return [] }
        let dir = own.deletingLastPathComponent()
        var paths = [own.path]
        for name in ["Kastellan", "kastellan-mcp"] {
            let candidate = dir.appendingPathComponent(name).path
            if candidate != own.path, FileManager.default.fileExists(atPath: candidate) { paths.append(candidate) }
        }
        return paths
    }

    public func secret(connectionID: String, key: String) async throws -> String? {
        try read(account: Self.account(connectionID, key))
    }

    /// Legt neu an oder ersetzt. Ersetzen läuft über Löschen und Anlegen, damit die ACL immer beide Programme enthält.
    public func set(connectionID: String, key: String, value: String) throws {
        let account = Self.account(connectionID, key)
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrLabel as String] = "Kastellan \(connectionID) \(key)"
        if let access = try makeAccess(label: "Kastellan \(connectionID) \(key)") {
            query[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status, "speichern") }
    }

    public func delete(connectionID: String, key: String) throws {
        let status = SecItemDelete(baseQuery(account: Self.account(connectionID, key)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, "löschen") }
    }

    /// Entfernt alle Einträge einer Verbindung.
    public func deleteAll(connectionID: String) throws {
        for account in try accounts().filter({ $0.hasPrefix(connectionID + "/") }) {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, "löschen") }
        }
    }

    public func exists(connectionID: String, key: String) -> Bool {
        (try? read(account: Self.account(connectionID, key))) != nil
    }

    /// Alle Schlüssel einer Verbindung (ohne Werte), für Diagnose.
    public func keys(connectionID: String) throws -> [String] {
        try accounts().filter { $0.hasPrefix(connectionID + "/") }.map { String($0.dropFirst(connectionID.count + 1)) }.sorted()
    }

    // MARK: - Intern

    static func account(_ connectionID: String, _ key: String) -> String { "\(connectionID)/\(key)" }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// ACL mit den vertrauenswürdigen Programmen. Die APIs sind seit macOS 12 als veraltet markiert,
    /// aber der einzige Weg ohne Access-Groups.
    private func makeAccess(label: String) throws -> SecAccess? {
        guard !trustedPaths.isEmpty else { return nil }
        var apps: [SecTrustedApplication] = []
        for path in trustedPaths {
            var app: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &app)
            if status == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        let status = SecAccessCreate(label as CFString, apps as CFArray, &access)
        guard status == errSecSuccess else { throw Self.error(status, "Zugriffsliste anlegen") }
        return access
    }

    private func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Self.error(status, "lesen") }
        return String(decoding: data, as: UTF8.self)
    }

    private func accounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw Self.error(status, "auflisten") }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func error(_ status: OSStatus, _ what: String) -> KastellanError {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .internal("Schlüsselbund \(what): \(text)")
    }
}

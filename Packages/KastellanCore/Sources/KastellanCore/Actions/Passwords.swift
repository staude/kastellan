import Foundation
import Security

/// Erzeugt Passwörter für Postfächer, FTP-User und Datenbanken.
public enum PasswordGenerator {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789-_.!")

    public static func generate(length: Int = 24) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// Schlüsselbund-Schlüssel für ein generiertes Passwort, etwa `mailbox/telemetrie@example.com`.
    public static func secretKey(_ resource: ResourceType, _ identifier: String) -> String {
        "\(resource.rawValue)/\(identifier)"
    }
}

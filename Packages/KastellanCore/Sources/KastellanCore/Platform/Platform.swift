import Foundation
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
#if canImport(FoundationXML)
@_exported import FoundationXML
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Plattformschicht: alles, was auf macOS, Linux und Windows unterschiedlich ist, liegt hier oder in
// den Secret-Stores daneben. Der Rest des Cores bleibt reines Foundation.

/// Name des Betriebssystems für Diagnose und Telemetrie.
public enum PlatformInfo {
    public static var name: String {
        #if os(macOS)
        "macOS"
        #elseif os(Linux)
        "Linux"
        #elseif os(Windows)
        "Windows"
        #else
        "unbekannt"
        #endif
    }
}

/// Kryptografisch sichere Zufallsbytes. `SystemRandomNumberGenerator` nutzt auf jeder Plattform den
/// sicheren Zufall des Systems (getrandom, BCryptGenRandom, arc4random).
enum SecureRandom {
    static func bytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }
}

/// SHA-256 über CryptoKit (Apple) oder swift-crypto (Linux, Windows); beide haben dieselbe API.
enum Digest {
    static func sha256(_ data: Data) -> [UInt8] { Array(SHA256.hash(data: data)) }
    static func sha256Hex(_ data: Data) -> String { sha256(data).map { String(format: "%02x", $0) }.joined() }
}

/// Plattformpassender Speicher für Provider-Zugangsdaten: Schlüsselbund auf macOS, Secret Service
/// (libsecret über `secret-tool`) auf Linux, Anmeldeinformationsverwaltung auf Windows.
public func makePlatformSecretStore() -> any ManagedSecretStore {
    #if canImport(Security)
    KeychainSecretStore()
    #elseif os(Windows)
    WindowsCredentialSecretStore()
    #else
    SecretToolSecretStore()
    #endif
}

/// Secret-Store, der Einträge einer Verbindung auflisten und gemeinsam löschen kann.
public protocol ManagedSecretStore: SecretStore {
    func keys(connectionID: String) throws -> [String]
    func deleteAll(connectionID: String) throws
    /// Kurzer Name für Diagnose und Hilfe, etwa „macOS-Schlüsselbund“.
    var displayName: String { get }
}

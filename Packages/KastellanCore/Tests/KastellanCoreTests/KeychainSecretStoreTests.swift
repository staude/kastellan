import Foundation
import Testing
@testable import KastellanCore

#if canImport(Security)

/// Läuft gegen den echten Login-Schlüsselbund mit eigenem Service-Namen und räumt auf.
/// In CI ohne entsperrten Schlüsselbund kann SecItemAdd scheitern, deshalb `KASTELLAN_SKIP_KEYCHAIN_TESTS`.
struct KeychainSecretStoreTests {
    static var skip: Bool { ProcessInfo.processInfo.environment["KASTELLAN_SKIP_KEYCHAIN_TESTS"] != nil }

    @Test(.enabled(if: !skip)) func setReadUpdateDelete() async throws {
        let store = KeychainSecretStore(service: "kastellan-tests-\(UUID().uuidString)")
        let conn = "conn-\(UUID().uuidString)"
        #expect(try await store.secret(connectionID: conn, key: "password") == nil)
        try store.set(connectionID: conn, key: "password", value: "geheim1")
        #expect(try await store.secret(connectionID: conn, key: "password") == "geheim1")
        try store.set(connectionID: conn, key: "password", value: "geheim2")
        #expect(try await store.secret(connectionID: conn, key: "password") == "geheim2")
        try store.set(connectionID: conn, key: "otp", value: "x")
        #expect(store.exists(connectionID: conn, key: "otp"))
        try store.deleteAll(connectionID: conn)
        #expect(try await store.secret(connectionID: conn, key: "password") == nil)
        #expect(!store.exists(connectionID: conn, key: "otp"))
        try store.delete(connectionID: conn, key: "nie-da")
    }
}
#endif

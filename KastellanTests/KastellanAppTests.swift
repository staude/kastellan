import Testing
import KastellanCore

struct KastellanAppTests {
    @Test func versionIsSet() {
        #expect(!KastellanCore.version.isEmpty)
    }
}

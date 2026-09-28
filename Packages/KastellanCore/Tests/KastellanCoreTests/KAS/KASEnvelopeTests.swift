import Foundation
import Testing
@testable import KastellanCore

struct KASEnvelopeTests {
    /// Vergleicht den gebauten Envelope mit dem Fixture: gleiche Hülle, gleiche JSON-Felder.
    private func compare(built: Data, fixture: String) throws -> (builtParams: [String: Any], fixtureParams: [String: Any]) {
        let builtText = String(decoding: built, as: UTF8.self)
        let fixtureText = try KASFixtures.string(fixture)
        let builtReq = KASRecordedRequest(url: KASEnvelope.apiURL, soapAction: "", body: builtText)
        let fixtureReq = KASRecordedRequest(url: KASEnvelope.apiURL, soapAction: "", body: fixtureText)
        // Hülle ohne den JSON-Teil muss identisch sein (Namespace, Operation, Attribute).
        func shell(_ text: String) -> String {
            guard let s = text.range(of: "<Params xsi:type=\"xsd:string\">"), let e = text.range(of: "</Params>") else { return text }
            return String(text[..<s.upperBound]) + String(text[e.lowerBound...])
        }
        #expect(shell(builtText).trimmingCharacters(in: .whitespacesAndNewlines) == shell(fixtureText).trimmingCharacters(in: .whitespacesAndNewlines))
        return (builtReq.params, fixtureReq.params)
    }

    @Test func authEnvelopeMatchesFixture() throws {
        let built = try KASEnvelope.auth(login: "w00abcde", password: "***", sessionLifetime: 600)
        let (mine, theirs) = try compare(built: built, fixture: "kasauth-request")
        #expect(Set(mine.keys) == Set(theirs.keys))
        #expect(mine["kas_login"] as? String == "w00abcde")
        #expect(mine["kas_auth_type"] as? String == "plain")
        #expect(mine["kas_auth_data"] as? String == "***")
        #expect(mine["session_lifetime"] as? Int == 600)
        #expect(mine["session_update_lifetime"] as? String == "Y")
        #expect(String(decoding: built, as: UTF8.self).contains("xmlns:ns1=\"urn:xmethodsKasApiAuthentication\""))
        #expect(String(decoding: built, as: UTF8.self).contains("<ns1:KasAuth>"))
    }

    @Test func authEnvelopeWithOTP() throws {
        let built = try KASEnvelope.auth(login: "w00abcde", password: "pw", otp: "123456")
        let params = KASRecordedRequest(url: KASEnvelope.authURL, soapAction: "", body: String(decoding: built, as: UTF8.self)).params
        #expect(params["session_2fa"] as? String == "123456")
        #expect(params["session_lifetime"] as? Int == 1800)
    }

    @Test func apiEnvelopeMatchesFixture() throws {
        let built = try KASEnvelope.api(login: "w00abcde", token: "***", action: "get_dkim", params: ["host": "example.com"])
        let (mine, theirs) = try compare(built: built, fixture: "get_dkim-request")
        #expect(Set(mine.keys) == Set(theirs.keys))
        #expect(mine["kas_auth_type"] as? String == "session")
        #expect(mine["kas_auth_data"] as? String == "***")
        #expect(mine["kas_action"] as? String == "get_dkim")
        #expect(mine["KasRequestParams"] as? [String: String] == ["host": "example.com"])
        #expect(theirs["KasRequestParams"] as? [String: String] == ["host": "example.com"])
        let text = String(decoding: built, as: UTF8.self)
        #expect(text.contains("xmlns:ns1=\"urn:xmethodsKasApi\""))
        #expect(text.contains("<ns1:KasApi>"))
    }

    @Test func emptyParamsAreJSONObject() throws {
        let built = try KASEnvelope.api(login: "l", token: "t", action: "get_domains")
        let text = String(decoding: built, as: UTF8.self)
        #expect(text.contains("&quot;KasRequestParams&quot;:{}") || text.contains("\"KasRequestParams\":{}"))
    }

    @Test func paramsAreXMLEscaped() throws {
        let built = try KASEnvelope.api(login: "l", token: "t", action: "add_dns_settings",
                                        params: ["record_data": "v=spf1 a mx <b> & c"])
        let text = String(decoding: built, as: UTF8.self)
        #expect(text.contains("&lt;b&gt; &amp; c"))
        #expect(!text.contains("<b>"))
        // Round-Trip über den Request-Decoder liefert den Originalwert.
        let params = KASRecordedRequest(url: KASEnvelope.apiURL, soapAction: "", body: text).requestParams
        #expect(params["record_data"] == "v=spf1 a mx <b> & c")
    }

    @Test func soapActionsAndURLs() {
        #expect(KASEnvelope.authSOAPAction == "urn:xmethodsKasApiAuthentication#KasAuth")
        #expect(KASEnvelope.apiSOAPAction == "urn:xmethodsKasApi#KasApi")
        #expect(KASEnvelope.authURL.absoluteString == "https://kasapi.kasserver.com/soap/KasAuth.php")
        #expect(KASEnvelope.apiURL.absoluteString == "https://kasapi.kasserver.com/soap/KasApi.php")
    }
}

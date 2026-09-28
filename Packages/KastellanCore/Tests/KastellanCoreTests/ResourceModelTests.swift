import Foundation
import Testing
@testable import KastellanCore

struct ResourceModelTests {
    let ref = ResourceRef(connectionID: "c1", providerRef: "m0123abc")

    @Test func mailboxRoundTripUsesSnakeCase() throws {
        let mb = Mailbox(ref: ref, address: "telemetrie@example.com", quotaMB: 1024, copyTo: ["a@b.de"],
                         extra: ["mail_allow_nets": .string("0.0.0.0/0")])
        let data = try JSONCoding.encoder.encode(mb)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"quota_mb\""))
        #expect(json.contains("\"connection_id\""))
        #expect(json.contains("\"provider_ref\""))
        #expect(!json.contains("password"))
        let back = try JSONCoding.decoder.decode(Mailbox.self, from: data)
        #expect(back == mb)
        #expect(back.localPart == "telemetrie")
        #expect(back.domainPart == "example.com")
    }

    @Test func dnsRecordProtection() {
        let mx = DNSRecord(ref: ref, zone: "example.com", name: "@", type: "mx", content: "mail.example", priority: 10)
        #expect(mx.type == "MX")
        #expect(mx.isProtected)
        let txt = DNSRecord(ref: ref, zone: "example.com", name: "kas1._domainkey", type: "TXT", content: "v=DKIM1")
        #expect(!txt.isProtected)
    }

    @Test func forwardStatusEncoding() throws {
        let fw = MailForward(ref: ref, address: "info@example.com", targets: ["user@example.net"], status: .pendingVerification)
        let json = String(decoding: try JSONCoding.encoder.encode(fw), as: UTF8.self)
        #expect(json.contains("\"pending_verification\""))
        #expect(json.contains("\"keep_copy\""))
    }

    @Test func dkimTxtRecord() {
        let k = DKIMKey(ref: ref, domain: "example.com", selector: "kas202609061725", publicKey: "MIIB")
        #expect(k.recordName == "kas202609061725._domainkey")
        #expect(k.txtRecord == "v=DKIM1; k=rsa; p=MIIB")
    }

    @Test func jsonValueRoundTrip() throws {
        let v: JSONValue = .object(["a": .int(1), "b": .array([.string("x"), .bool(true), .null]), "c": .double(1.5)])
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back == v)
        #expect(JSONValue.int(7).stringValue == "7")
    }

    @Test func connectionHasNoSecretField() throws {
        let c = Connection(profileID: "ctx", provider: "allinkl", label: "All-Inkl beispiel", settings: ["kas_login": "w00abcde"])
        let json = String(decoding: try JSONCoding.encoder.encode(c), as: UTF8.self)
        #expect(json.contains("\"created_at\""))
        #expect(!json.lowercased().contains("password"))
    }
}

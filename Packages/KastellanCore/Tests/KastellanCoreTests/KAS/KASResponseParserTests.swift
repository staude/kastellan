import Foundation
import Testing
@testable import KastellanCore

struct KASResponseParserTests {
    @Test func authResponseYieldsToken() throws {
        let token = try KASResponseParser.parseAuth(try KASFixtures.response("kasauth"))
        #expect(token == "***")
    }

    @Test func topLevelStructureHasRequestAndResponse() throws {
        let response = try KASResponseParser.parseAPI(try KASFixtures.response("get_dkim"))
        #expect(response.floodDelay == 0.5)
        #expect(response.returnString == "TRUE")
        #expect(response.raw["Request"]?.string("KasRequestType") == "get_dkim")
        #expect(response.raw["Request"]?["KasRequestParams"]?.string("host") == "example.com")
        #expect(response.raw["Request"]?.string("KasRequestTime") == "1788717588")
    }

    @Test func dkimArrayOfMaps() throws {
        let response = try KASResponseParser.parseAPI(try KASFixtures.response("get_dkim"))
        #expect(response.items.count == 1)
        let item = try #require(response.items.first)
        #expect(item.string("selector") == "kas202609061725")
        #expect(item.string("valid_to") == "2027-03-05")
        #expect(item.string("public_key")?.hasPrefix("MIIBIjAN") == true)
    }

    @Test func emptyRequestParamsAreEmptyArray() throws {
        let response = try KASResponseParser.parseAPI(try KASFixtures.response("get_domains"))
        #expect(response.raw["Request"]?["KasRequestParams"] == .array([]))
    }

    @Test(arguments: [
        ("get_domains", "domain_name", ["beispiel-shop.com", "mustermann.example"]),
        ("get_subdomains", "subdomain_name", ["planer.beispiel-app.de", "cloud.beispiel-aktion.org"]),
        ("get_dns_settings", "record_id", ["120313043", "120313045"]),
        ("get_mailaccounts", "mail_login", ["m0abcd01", "m0abcd02"]),
        ("get_mailforwards", "mail_forward_address", ["info@beispiel-aktion.org", "kino@beispiel-verein.de"]),
        ("get_ftpusers", "ftp_login", ["w00abcde", "f0abcd12"]),
        ("get_databases", "database_login", ["d0abcd02", "d0abcd01"]),
        ("get_cronjobs", "cronjob_id", ["320775", "324135"]),
    ])
    func listFixturesHaveTwoItems(action: String, key: String, expected: [String]) throws {
        let response = try KASResponseParser.parseAPI(try KASFixtures.response(action))
        #expect(response.returnString == "TRUE")
        #expect(response.floodDelay == 0.5)
        #expect(response.items.count == 2)
        #expect(response.items.map { $0.string(key) } == expected)
    }

    @Test func domainsFieldsAndTypes() throws {
        let items = try KASResponseParser.parseAPI(try KASFixtures.response("get_domains")).items
        let first = try #require(items.first)
        #expect(first.string("domain_path") == "/beispiel-shop.com/")
        #expect(first.string("domain_redirect_status") == "0")
        #expect(first.string("dkim_selector") == "kas202502031742")
        #expect(first.bool("is_active") == true)
        #expect(first.bool("in_progress") == false)
        #expect(first.string("php_version") == "8.3")
        #expect(first.map?.count == 15)
    }

    @Test func nilAndEmptyValuesBecomeNil() throws {
        let items = try KASResponseParser.parseAPI(try KASFixtures.response("get_subdomains")).items
        let first = try #require(items.first)
        // xsi:nil="true"
        #expect(first["ssl_certificate_sni_key"] == .scalar(nil))
        #expect(first.string("ssl_certificate_sni_force_https") == nil)
        // leeres Element
        let second = try #require(items.last)
        #expect(second["statistic_language"] == .scalar(nil))
        #expect(second.string("statistic_language") == nil)
        // Schlüssel bleibt vorhanden
        #expect(second.map?["statistic_language"] != nil)
    }

    @Test func dnsApexRecordHasEmptyName() throws {
        let items = try KASResponseParser.parseAPI(try KASFixtures.response("get_dns_settings")).items
        let apex = try #require(items.first)
        #expect(apex.string("record_name") == nil)
        #expect(apex.string("record_zone") == "example.com")
        #expect(apex.string("record_type") == "A")
        #expect(apex.string("record_data") == "192.0.2.45")
        #expect(apex.int("record_aux") == 0)
        #expect(apex.bool("record_changeable") == true)
        let wildcard = try #require(items.last)
        #expect(wildcard.string("record_name") == "*")
        #expect(wildcard.string("record_data") == "w00abcde.kasserver.com.")
    }

    @Test func mailaccountFloatsAndLists() throws {
        let items = try KASResponseParser.parseAPI(try KASFixtures.response("get_mailaccounts")).items
        let first = try #require(items.first)
        #expect(first.double("used_mailaccount_space") == 47.1025390625)
        #expect(first.string("mail_spamfilter") == "pdw,sf")
        #expect(first.string("mail_password") == nil)
        #expect(first.string("mail_addresses") == "webseite@beispiel-verein.de")
    }

    @Test func cronjobFields() throws {
        let items = try KASResponseParser.parseAPI(try KASFixtures.response("get_cronjobs")).items
        let first = try #require(items.first)
        #expect(first.string("protocol") == "https")
        #expect(first.string("minute") == "50")
        #expect(first.string("hour") == "7")
        #expect(first["shell_command"] == .scalar(nil))
        #expect(first.string("mail_subject") == "comment")
    }

    @Test func scalarReturnInfo() throws {
        let response = try KASResponseParser.parseAPI(try KASFixtures.response("delete_session"))
        #expect(response.returnInfo == .scalar("***"))
        #expect(response.returnInfo.string == "***")
        #expect(response.items.isEmpty)
    }

    @Test func faultBecomesProviderError() throws {
        let data = try KASFixtures.data("fault-zone_not_found")
        let fault = try #require(throws: KASFault.self) { try KASResponseParser.parseAPI(data) }
        #expect(fault.faultstring == "zone_not_found")
        #expect(fault.detail == "gibt-es-nicht-example.com")
        #expect(fault.faultcode == "SOAP-ENV:Server")
        #expect(fault.kastellanError == .provider("zone_not_found: gibt-es-nicht-example.com"))
        #expect(!fault.isFloodProtection)
        #expect(!fault.isSessionInvalid)
    }

    @Test func faultClassification() {
        #expect(KASFault(faultstring: "flood_protection").isFloodProtection)
        #expect(KASFault(faultstring: "session_expired").isSessionInvalid)
        #expect(KASFault(faultstring: "auth_failed").isSessionInvalid)
        #expect(KASFault(faultstring: "unknown_action").isUnknownAction)
        #expect(KASFault(faultstring: "zone_not_found").message == "zone_not_found")
    }

    @Test func invalidXMLIsProviderError() {
        #expect(throws: KastellanError.self) {
            try KASResponseParser.parseAPI(Data("<nicht xml".utf8))
        }
    }

    @Test func valueHelpers() {
        let map = KASValue.map(["a": .scalar("Y"), "b": .scalar(""), "n": .scalar("12")])
        #expect(map.bool("a") == true)
        #expect(map.string("b") == nil)
        #expect(map.int("n") == 12)
        #expect(map.array?.count == 1)
        #expect(KASValue.scalar(nil).array == [])
        #expect(KASValue.scalar("x").array == nil)
        #expect(map.jsonValue == .object(["a": .string("Y"), "b": .string(""), "n": .string("12")]))
    }
}

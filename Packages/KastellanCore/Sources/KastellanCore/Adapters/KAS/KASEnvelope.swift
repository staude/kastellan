import Foundation

// SOAP-Envelope für die KAS-API von Hand. Es gibt genau zwei Operationen: `KasAuth` (Session
// anlegen) und `KasApi` (alles andere). Beide nehmen einen JSON-String im Element `Params`.
// Der Aufbau entspricht dem, was der PHP-SoapClient sendet (Fixtures `*-request.xml`).

public enum KASEnvelope {
    public static let authURL = URL(string: "https://kasapi.kasserver.com/soap/KasAuth.php")!
    public static let apiURL = URL(string: "https://kasapi.kasserver.com/soap/KasApi.php")!

    public static let authNamespace = "urn:xmethodsKasApiAuthentication"
    public static let apiNamespace = "urn:xmethodsKasApi"

    public static let authSOAPAction = "\(authNamespace)#KasAuth"
    public static let apiSOAPAction = "\(apiNamespace)#KasApi"

    /// Envelope für `KasAuth`: legt eine Session an und liefert einen CredentialToken.
    public static func auth(login: String, password: String, sessionLifetime: Int = 1800,
                            updateLifetime: Bool = true, otp: String? = nil) throws -> Data {
        var params: [String: Any] = [
            "kas_login": login,
            "kas_auth_type": "plain",
            "kas_auth_data": password,
            "session_lifetime": sessionLifetime,
            "session_update_lifetime": updateLifetime ? "Y" : "N",
        ]
        if let otp, !otp.isEmpty { params["session_2fa"] = otp }
        return Data(envelope(namespace: authNamespace, operation: "KasAuth", paramsJSON: try json(params)).utf8)
    }

    /// Envelope für `KasApi` mit Session-Token. `KasRequestParams` ist immer ein JSON-Objekt,
    /// auch wenn es leer ist (PHP sendet `(object) []`).
    public static func api(login: String, token: String, action: String, params: [String: String] = [:]) throws -> Data {
        let body: [String: Any] = [
            "kas_login": login,
            "kas_auth_type": "session",
            "kas_auth_data": token,
            "kas_action": action,
            "KasRequestParams": params,
        ]
        return Data(envelope(namespace: apiNamespace, operation: "KasApi", paramsJSON: try json(body)).utf8)
    }

    static func envelope(namespace: String, operation: String, paramsJSON: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:ns1=\"\(namespace)\""
            + " xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
            + " xmlns:SOAP-ENC=\"http://schemas.xmlsoap.org/soap/encoding/\""
            + " SOAP-ENV:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<SOAP-ENV:Body><ns1:\(operation)><Params xsi:type=\"xsd:string\">\(escape(paramsJSON))</Params></ns1:\(operation)>"
            + "</SOAP-ENV:Body></SOAP-ENV:Envelope>"
    }

    static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw KastellanError.internal("KAS-Parameter lassen sich nicht als JSON kodieren")
        }
        return text
    }

    /// XML-Escaping für Text innerhalb von `<Params>`.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(ch)
            }
        }
        return out
    }
}

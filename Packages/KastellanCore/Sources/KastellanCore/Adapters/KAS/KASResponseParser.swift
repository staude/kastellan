import Foundation

// Antwort-Parser für KAS-SOAP-Antworten auf Basis von Foundation `XMLParser`. Baut zuerst einen
// kleinen Elementbaum, dann wird `return` generisch in `KASValue` übersetzt:
// `ns2:Map` zu Dictionary, `SOAP-ENC:Array` zu Array, alles andere zu Skalar.

/// SOAP-Fault der KAS-API, etwa `zone_not_found` mit Detail `gibt-es-nicht-example.com`.
public struct KASFault: Error, Equatable, Sendable {
    public let faultcode: String?
    public let faultstring: String
    public let detail: String?

    public init(faultcode: String? = nil, faultstring: String, detail: String? = nil) {
        self.faultcode = faultcode
        self.faultstring = faultstring
        self.detail = detail
    }

    /// Flood-Schutz: kurz warten und erneut versuchen.
    public var isFloodProtection: Bool {
        faultstring.lowercased().contains("flood")
    }

    /// Session abgelaufen oder ungültig: neu anmelden und erneut versuchen.
    public var isSessionInvalid: Bool {
        let f = faultstring.lowercased()
        return f.contains("session") || f.contains("auth")
    }

    /// Die API kennt die Aktion nicht (undokumentierte Funktionen wie `add_dkim`).
    public var isUnknownAction: Bool {
        let f = faultstring.lowercased()
        return f.contains("action") || f.contains("function") || f.contains("unknown") || f.contains("not_implemented")
    }

    public var message: String {
        if let detail, !detail.isEmpty { return "\(faultstring): \(detail)" }
        return faultstring
    }

    public var kastellanError: KastellanError { .provider(message) }
}

/// Zerlegte `KasApi`-Antwort.
public struct KASAPIResponse: Sendable, Equatable {
    /// Ganze `return`-Map mit `Request` und `Response`.
    public let raw: KASValue
    /// Sekunden, die vor dem nächsten Aufruf zu warten sind.
    public let floodDelay: Double
    public let returnString: String?
    /// Nutzdaten: Array von Maps, einzelne Map oder Skalar.
    public let returnInfo: KASValue

    public init(raw: KASValue, floodDelay: Double, returnString: String?, returnInfo: KASValue) {
        self.raw = raw; self.floodDelay = floodDelay; self.returnString = returnString; self.returnInfo = returnInfo
    }

    /// `ReturnInfo` als Liste von Maps, leer bei leerem Ergebnis.
    public var items: [KASValue] {
        returnInfo.array ?? []
    }
}

public enum KASResponseParser {
    /// Antwort auf `KasAuth`: der CredentialToken.
    public static func parseAuth(_ data: Data) throws -> String {
        let value = try parseReturn(data)
        guard let token = value.string, !token.isEmpty else {
            throw KastellanError.provider("KasAuth lieferte keinen Token")
        }
        return token
    }

    /// Antwort auf `KasApi`.
    public static func parseAPI(_ data: Data) throws -> KASAPIResponse {
        let value = try parseReturn(data)
        guard let response = value["Response"] else {
            throw KastellanError.provider("KasApi-Antwort ohne Response-Teil")
        }
        return KASAPIResponse(
            raw: value,
            floodDelay: response.double("KasFloodDelay") ?? 0,
            returnString: response.string("ReturnString"),
            returnInfo: response["ReturnInfo"] ?? .scalar(nil)
        )
    }

    /// Liefert das `return`-Element des Bodys als Wertebaum, wirft `KASFault` bei einem SOAP-Fault.
    public static func parseReturn(_ data: Data) throws -> KASValue {
        let root = try Tree.parse(data)
        guard let body = root.first(named: "Envelope")?.first(named: "Body") ?? root.first(named: "Body") else {
            throw KastellanError.provider("SOAP-Antwort ohne Body")
        }
        if let fault = body.first(named: "Fault") {
            throw KASFault(
                faultcode: fault.first(named: "faultcode")?.text,
                faultstring: fault.first(named: "faultstring")?.text ?? "unbekannter Fehler",
                detail: fault.first(named: "detail")?.text
            )
        }
        guard let ret = body.children.first?.first(named: "return") else {
            throw KastellanError.provider("SOAP-Antwort ohne return-Element")
        }
        return convert(ret)
    }

    // MARK: - Baum zu KASValue

    static func convert(_ element: Element) -> KASValue {
        if element.attribute("nil") == "true" { return .scalar(nil) }
        let type = element.attribute("type") ?? ""
        let items = element.children.filter { $0.name == "item" }

        if type.hasSuffix(":Array") {
            return .array(items.map(convert))
        }
        if type.hasSuffix(":Map") || (!items.isEmpty && items.allSatisfy { $0.first(named: "key") != nil }) {
            var map: [String: KASValue] = [:]
            for item in items {
                guard let key = item.first(named: "key")?.text else { continue }
                map[key] = item.first(named: "value").map(convert) ?? .scalar(nil)
            }
            return .map(map)
        }
        if !items.isEmpty {
            return .array(items.map(convert))
        }
        let text = element.text
        return .scalar(text.isEmpty ? nil : text)
    }

    // MARK: - Elementbaum

    final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Element] = []
        var text = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func first(named name: String) -> Element? {
            children.first { $0.name == name }
        }

        /// Attribut ohne Namensraum-Präfix, etwa `type` für `xsi:type`.
        func attribute(_ localName: String) -> String? {
            if let v = attributes[localName] { return v }
            return attributes.first { $0.key.hasSuffix(":" + localName) }?.value
        }
    }

    final class Tree: NSObject, XMLParserDelegate {
        private let root = Element(name: "", attributes: [:])
        private var stack: [Element] = []
        private var error: Error?

        static func parse(_ data: Data) throws -> Element {
            let tree = Tree()
            let parser = XMLParser(data: data)
            parser.delegate = tree
            parser.shouldProcessNamespaces = false
            guard parser.parse(), tree.error == nil else {
                let reason = (tree.error ?? parser.parserError)?.localizedDescription ?? "unbekannt"
                throw KastellanError.provider("KAS-Antwort ist kein gültiges XML: \(reason)")
            }
            return tree.root
        }

        private override init() {
            super.init()
            stack = [root]
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let element = Element(name: local, attributes: attributeDict)
            stack.last?.children.append(element)
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if stack.count > 1 { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            error = parseError
        }
    }
}

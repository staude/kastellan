import Foundation

/// Schlanker XML-Baum für Namecheap-Antworten. Namensräume werden entfernt, Element- und
/// Attributnamen bleiben wie geliefert (Namecheap mischt Groß- und Kleinschreibung, etwa `host`).
public struct NamecheapXMLElement: Sendable, Equatable {
    public var name: String
    public var attributes: [String: String]
    public var children: [NamecheapXMLElement]
    public var text: String

    public init(name: String, attributes: [String: String] = [:], children: [NamecheapXMLElement] = [], text: String = "") {
        self.name = name; self.attributes = attributes; self.children = children; self.text = text
    }

    public subscript(_ attribute: String) -> String? { attributes[attribute] }

    /// Erstes direktes Kind mit diesem Namen (ohne Rücksicht auf Groß- und Kleinschreibung).
    public func child(_ name: String) -> NamecheapXMLElement? {
        children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func children(_ name: String) -> [NamecheapXMLElement] {
        children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Alle Nachfahren mit diesem Namen in Dokumentreihenfolge.
    public func descendants(_ name: String) -> [NamecheapXMLElement] {
        var out: [NamecheapXMLElement] = []
        for child in children {
            if child.name.caseInsensitiveCompare(name) == .orderedSame { out.append(child) }
            out += child.descendants(name)
        }
        return out
    }

    public func firstDescendant(_ name: String) -> NamecheapXMLElement? {
        for child in children {
            if child.name.caseInsensitiveCompare(name) == .orderedSame { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    public func bool(_ attribute: String) -> Bool? {
        guard let v = attributes[attribute]?.lowercased() else { return nil }
        switch v {
        case "true", "yes", "1", "enabled", "ok": return true
        case "false", "no", "0", "disabled": return false
        default: return nil
        }
    }

    public func int(_ attribute: String) -> Int? { attributes[attribute].flatMap { Int($0) } }

    public static func parse(_ data: Data) throws -> NamecheapXMLElement {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw KastellanError.provider("Namecheap: Antwort ist kein gültiges XML (\(parser.parserError?.localizedDescription ?? "leer"))")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [NamecheapXMLElement] = []
        var root: NamecheapXMLElement?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(NamecheapXMLElement(name: elementName, attributes: attributeDict))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard var element = stack.popLast() else { return }
            element.text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if stack.isEmpty { root = element } else { stack[stack.count - 1].children.append(element) }
        }
    }
}

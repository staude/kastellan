import Foundation

// Generischer Wertebaum einer KAS-Antwort. Die API liefert `ns2:Map` (Schlüssel/Wert-Paare),
// `SOAP-ENC:Array` (Folge von Maps oder Skalaren) und Skalare (`xsd:string`, `xsd:int`,
// `xsd:float`). Leere Elemente und `xsi:nil` werden zu `nil`.

public indirect enum KASValue: Sendable, Equatable {
    case scalar(String?)
    case map([String: KASValue])
    case array([KASValue])

    /// Skalarer Text, `nil` bei leerem Wert oder wenn es kein Skalar ist.
    public var string: String? {
        if case .scalar(let s) = self { return s }
        return nil
    }

    public var map: [String: KASValue]? {
        if case .map(let m) = self { return m }
        return nil
    }

    /// Array-Elemente. Eine einzelne Map wird als Array mit einem Element geliefert,
    /// ein leerer Skalar als leeres Array.
    public var array: [KASValue]? {
        switch self {
        case .array(let a): a
        case .map: [self]
        case .scalar(let s): (s ?? "").isEmpty ? [] : nil
        }
    }

    /// Schlüsselzugriff auf eine Map, `nil` bei anderen Typen.
    public subscript(key: String) -> KASValue? {
        map?[key]
    }

    /// Skalarer Text unter einem Schlüssel, leere Strings als `nil`.
    public func string(_ key: String) -> String? {
        guard let s = self[key]?.string, !s.isEmpty else { return nil }
        return s
    }

    public func int(_ key: String) -> Int? {
        string(key).flatMap { Int($0) }
    }

    public func double(_ key: String) -> Double? {
        string(key).flatMap { Double($0) }
    }

    /// `Y`/`N`, `j`/`n`, `TRUE`/`FALSE`, `1`/`0` als Bool.
    public func bool(_ key: String) -> Bool? {
        guard let s = string(key)?.lowercased() else { return nil }
        switch s {
        case "y", "j", "true", "1", "yes": return true
        case "n", "false", "0", "no": return false
        default: return nil
        }
    }

    /// Ist der Wert leer (nil-Skalar, leerer String, leere Map, leeres Array)?
    public var isEmpty: Bool {
        switch self {
        case .scalar(let s): (s ?? "").isEmpty
        case .map(let m): m.isEmpty
        case .array(let a): a.isEmpty
        }
    }

    /// Übersetzt den Wert in `JSONValue`, etwa für `extra`.
    public var jsonValue: JSONValue {
        switch self {
        case .scalar(let s): s.map(JSONValue.string) ?? .null
        case .map(let m): .object(m.mapValues(\.jsonValue))
        case .array(let a): .array(a.map(\.jsonValue))
        }
    }
}

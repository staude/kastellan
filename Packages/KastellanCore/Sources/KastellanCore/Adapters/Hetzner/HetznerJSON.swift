import Foundation

// Kleine Zugriffshelfer auf `JSONValue` für die Hetzner-Antworten. Die Cloud API liefert
// verschachtelte Objekte (`public_net.ipv4.ip`), die hier ohne eigene Codable-Typen gelesen
// werden. Fehlende oder leere Werte sind `nil`, damit das Mapping keine Annahmen erzwingt.

extension JSONValue {
    /// Schlüsselzugriff auf ein Objekt, `nil` bei anderen Typen.
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Ganzzahl aus `.int`, ganzzahligem `.double` oder numerischem String.
    var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d): d.rounded() == d ? Int(d) : nil
        case .string(let s): Int(s)
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// String unter einem Schlüssel, leere Strings als `nil`. Zahlen werden zu Text.
    func string(_ key: String) -> String? {
        guard let v = self[key], let s = v.stringValue, !s.isEmpty else { return nil }
        return s
    }

    func int(_ key: String) -> Int? {
        self[key]?.intValue
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func array(_ key: String) -> [JSONValue] {
        self[key]?.arrayValue ?? []
    }

    /// Alle String-Elemente eines Arrays unter einem Schlüssel.
    func strings(_ key: String) -> [String] {
        array(key).compactMap(\.stringValue)
    }

    /// Hetzner-Labels (`key/value`-Paare) als Dictionary.
    func labels(_ key: String = "labels") -> [String: String] {
        guard let o = self[key]?.objectValue else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in o { if let s = v.stringValue { out[k] = s } }
        return out
    }

    /// Objekt aus `[String: String]`, etwa für Labels im Request.
    static func labels(_ labels: [String: String]) -> JSONValue {
        .object(labels.mapValues { .string($0) })
    }

    /// Nur vorhandene Werte übernehmen (`nil` lässt den Schlüssel weg).
    static func compactObject(_ pairs: [String: JSONValue?]) -> JSONValue {
        var o: [String: JSONValue] = [:]
        for (k, v) in pairs { if let v { o[k] = v } }
        return .object(o)
    }
}

enum HetznerDates {
    /// RFC 3339 (`2016-01-30T23:55:00Z`, auch mit Offset oder Bruchteilen) als Datum.
    /// Die Formatter entstehen je Aufruf, weil `ISO8601DateFormatter` nicht Sendable ist.
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

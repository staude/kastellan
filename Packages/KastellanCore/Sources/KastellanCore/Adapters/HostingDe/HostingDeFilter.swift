import Foundation

// Filter der `…Find`-Methoden von hosting.de: einzelne Bedingungen `{field, value, relation}`
// oder Ketten `{subFilterConnective, subFilter}`. Feldnamen sind je Methode festgelegt
// (`ZoneName`, `MailboxEmailAddress`, `AccountId` …), `*` ist Platzhalter.

public indirect enum HostingDeFilter: Sendable, Equatable {
    public enum Relation: String, Sendable {
        case equal, unequal, greater, less, greaterEqual, lessEqual
    }

    case condition(field: String, value: String, relation: Relation)
    case and([HostingDeFilter])
    case or([HostingDeFilter])

    public static func equal(_ field: String, _ value: String) -> HostingDeFilter {
        .condition(field: field, value: value, relation: .equal)
    }

    public static func unequal(_ field: String, _ value: String) -> HostingDeFilter {
        .condition(field: field, value: value, relation: .unequal)
    }

    /// JSON-Form für den Parameter `filter`.
    public var json: JSONValue {
        switch self {
        case .condition(let field, let value, let relation):
            var o: [String: JSONValue] = ["field": .string(field), "value": .string(value)]
            if relation != .equal { o["relation"] = .string(relation.rawValue) }
            return .object(o)
        case .and(let parts):
            return .object(["subFilterConnective": .string("AND"), "subFilter": .array(parts.map(\.json))])
        case .or(let parts):
            return .object(["subFilterConnective": .string("OR"), "subFilter": .array(parts.map(\.json))])
        }
    }
}

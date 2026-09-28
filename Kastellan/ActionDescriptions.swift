import KastellanCore

/// Deutsche Kurzbeschreibung je Katalog-Aktion für Protokoll und Übersicht.
enum ActionDescriptions {
    static let german: [String: String] = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.name, $0.descriptionDE) })
}

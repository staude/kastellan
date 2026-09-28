import SwiftUI
import KastellanCore

/// Bereich „Protokoll“: audit.jsonl mit Filtern, sortierbaren Spalten, Mouse-over und Detailansicht per Doppelklick.
struct AuditView: View {
    let model: AppModel
    @State private var entries: [AuditEntry] = []
    @State private var client = ""
    @State private var days = 7
    @State private var onlyProblems = false
    @State private var sortOrder = [KeyPathComparator(\AuditRow.timestamp, order: .reverse)]
    @State private var selection: AuditRow.ID?
    @State private var detail: AuditRow?

    /// Flache Zeile für die Tabelle, damit Sortierung über KeyPaths funktioniert.
    struct AuditRow: Identifiable, Sendable {
        let entry: AuditEntry
        var id: String { entry.id }
        var timestamp: Date { entry.timestamp }
        var client: String { entry.client }
        var connection: String
        var tool: String { entry.tool ?? entry.capability?.description ?? "" }
        var target: String { entry.target ?? "" }
        var outcome: String { entry.outcome.rawValue }
        var details: String { [entry.message, entry.providerCall, entry.durationMS.map { "\($0) ms" }].compactMap { $0 }.joined(separator: ", ") }
        var duration: Int { entry.durationMS ?? -1 }
    }

    private var rows: [AuditRow] {
        entries.map { AuditRow(entry: $0, connection: $0.connectionID.map(model.connectionLabel) ?? "") }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Client", text: $client).frame(width: 160)
                Picker("Zeitraum", selection: $days) {
                    Text("Heute").tag(1); Text("7 Tage").tag(7); Text("30 Tage").tag(30); Text("Alles").tag(3650)
                }
                .frame(width: 180)
                Toggle("Nur Probleme", isOn: $onlyProblems)
                Spacer()
                Text("Doppelklick auf eine Zeile zeigt alle Details").kFont(.caption).foregroundStyle(.secondary)
                Button("Aktualisieren") { load() }
            }
            .padding(10)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Zeit", value: \.timestamp) { r in cell(r.timestamp.short, r) }.width(min: 110, ideal: 150)
                TableColumn("Client", value: \.client) { r in cell(r.client, r) }.width(min: 70, ideal: 110)
                TableColumn("Verbindung", value: \.connection) { r in cell(r.connection, r) }.width(min: 80, ideal: 140)
                TableColumn("Tool", value: \.tool) { r in cell(r.tool, r) }.width(min: 100, ideal: 200)
                TableColumn("Ziel", value: \.target) { r in cell(r.target, r) }.width(min: 60, ideal: 160)
                TableColumn("Ergebnis", value: \.outcome) { r in
                    cell(r.outcome, r).foregroundStyle(outcomeColor(r.entry.outcome))
                }.width(min: 70, ideal: 90)
                TableColumn("Dauer", value: \.duration) { r in cell(r.entry.durationMS.map { "\($0) ms" } ?? "", r).foregroundStyle(.secondary) }.width(min: 60, ideal: 80)
                TableColumn("Details", value: \.details) { r in cell(r.details, r).foregroundStyle(.secondary) }.width(min: 100, ideal: 260)
            }
            .contextMenu(forSelectionType: AuditRow.ID.self) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Details anzeigen") { detail = row }
                }
            } primaryAction: { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) { detail = row }
            }
        }
        .navigationTitle("Protokoll")
        .task { load() }
        .onChange(of: client) { load() }
        .onChange(of: days) { load() }
        .onChange(of: onlyProblems) { load() }
        .sheet(item: $detail) { row in AuditDetailView(row: row, model: model) }
    }

    /// Zelle mit Mouse-over: voller Inhalt und Hinweis auf Doppelklick.
    private func cell(_ text: String, _ row: AuditRow) -> some View {
        Text(text).lineLimit(1).help(text.isEmpty ? "Doppelklick zeigt alle Details" : "\(text)\n\nDoppelklick zeigt alle Details")
    }

    private func load() {
        let filter = AuditFilter(client: client.isEmpty ? nil : client, since: Date(timeIntervalSinceNow: -Double(days) * 86400), limit: 5000)
        var list = (try? model.runtime.audit.entries(filter)) ?? []
        if onlyProblems { list = list.filter { $0.outcome != .ok && $0.outcome != .confirmed && $0.outcome != .pending } }
        entries = list
    }

    private func outcomeColor(_ o: AuditEntry.Outcome) -> Color {
        switch o {
        case .ok, .confirmed: Theme.ok
        case .pending: Theme.warn
        default: Theme.bad
        }
    }
}

/// Alle Felder eines Protokolleintrags, zum Kopieren.
struct AuditDetailView: View {
    let row: AuditView.AuditRow
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var fields: [(String, String)] {
        let e = row.entry
        return [
            ("Zeit", e.timestamp.formatted(date: .long, time: .standard)),
            ("Client", e.client),
            ("Verbindung", row.connection.isEmpty ? "" : "\(row.connection) (\(e.connectionID ?? ""))"),
            ("Tool", e.tool ?? ""),
            ("Ressource:Aktion", e.capability?.description ?? ""),
            ("Ziel", e.target ?? ""),
            ("Ergebnis", e.outcome.rawValue),
            ("Meldung", e.message ?? ""),
            ("Provider-Aufruf", e.providerCall ?? ""),
            ("Dauer", e.durationMS.map { "\($0) ms" } ?? ""),
            ("Freigabe", e.pendingActionID ?? ""),
            ("Eintrag", e.id),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Protokolleintrag").kFont(.title3, weight: .semibold)
            Card {
                ForEach(Array(fields.enumerated()), id: \.offset) { i, f in
                    CardRow(last: i == fields.count - 1) {
                        Text(f.0).kFont(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text(f.1).kFont(.body, design: f.0 == "Eintrag" || f.0 == "Freigabe" ? .monospaced : .default)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Button("Alles kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
        .background(Theme.background)
    }
}

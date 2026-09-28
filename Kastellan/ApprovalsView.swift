import SwiftUI
import KastellanCore

/// Bereich „Freigaben“: offene Pending Actions mit Vorschau, Freigeben und Verwerfen, dazu die letzten Ergebnisse.
struct ApprovalsView: View {
    let model: AppModel

    var body: some View {
        List {
            if !model.handoffs.isEmpty {
                Section("Zugänge, die auf Ablage warten") {
                    ForEach(model.handoffs) { h in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.record.title).kFont(.body, weight: .medium)
                                Text("\(h.kind.displayName)\(h.target.description.isEmpty ? "" : ", \(h.target.description)") · \(h.createdAt.short)" + (h.lastError.map { " · Fehler: \($0)" } ?? ""))
                                    .kFont(.caption).foregroundStyle(h.lastError == nil ? .secondary : Theme.bad)
                            }
                            Spacer()
                            Button("Jetzt ablegen") { Task { await model.processHandoffs(retryFailed: true) } }
                                .disabled(h.kind == .bitwarden && model.bitwardenSession == nil)
                            if h.kind == .bitwarden && model.bitwardenSession == nil {
                                Text("Bitwarden in den Einstellungen entsperren").kFont(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Offen") {
                if model.pendingActions.isEmpty {
                    Text("Keine offenen Freigaben.").foregroundStyle(.secondary)
                }
                ForEach(model.pendingActions) { action in
                    PendingRow(model: model, action: action, open: true)
                }
            }
            Section("Zuletzt") {
                ForEach(model.recentActions) { action in
                    PendingRow(model: model, action: action, open: false)
                }
            }
        }
        .navigationTitle("Freigaben")
        .toolbar {
            Button { Task { await model.reloadPending() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
        }
    }
}

struct PendingRow: View {
    let model: AppModel
    let action: PendingAction
    let open: Bool
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.preview).kFont(.headline)
                    Text("\(action.capability.description) · \(model.connectionLabel(action.connectionID)) · Client \(action.client) · \(action.createdAt.short)")
                        .kFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if open, model.canDecide(action) {
                    Button("Verwerfen", role: .destructive) { Task { await model.reject(action) } }
                    Button("Freigeben") { Task { await model.approve(action) } }.buttonStyle(.borderedProminent)
                } else if open {
                    ProgressView().controlSize(.small)
                    Text(action.status == .executing ? "wird ausgeführt" : "läuft").kFont(.caption).foregroundStyle(.secondary)
                } else {
                    Text(action.status.rawValue)
                        .kFont(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(action.status == .done ? Color.green.opacity(0.2) : (action.status == .failed ? Color.red.opacity(0.2) : Color.gray.opacity(0.2)), in: Capsule())
                }
            }
            DisclosureGroup("Details", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    if !action.parameters.isEmpty {
                        Text("Parameter").kFont(.caption).foregroundStyle(.secondary)
                        ForEach(action.parameters.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(action.parameters[key]?.description ?? "")").kFont(.caption, design: .monospaced)
                        }
                    }
                    if let result = action.result {
                        Text("Ergebnis").kFont(.caption).foregroundStyle(.secondary)
                        Text(result.description).kFont(.caption, design: .monospaced).textSelection(.enabled)
                    }
                    if let error = action.error {
                        Text("Fehler: \(error)").kFont(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.top, 4)
            }
            .kFont(.caption)
        }
        .padding(.vertical, 4)
    }
}

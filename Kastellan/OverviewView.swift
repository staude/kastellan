import SwiftUI
import KastellanCore

/// Startseite nach TorroMail-Vorbild: Banner, Status, Verbindungen, Freigaben, letzte Aktivität.
struct OverviewView: View {
    let model: AppModel
    let navigate: (AppModel.Section) -> Void
    @State private var recent: [AuditEntry] = []

    private var lastClientUse: Date? { model.tokens.compactMap(\.lastUsedAt).max() }
    private var clientsConnected: Bool { lastClientUse.map { Date().timeIntervalSince($0) < 86400 } ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HeaderBanner()
                VStack(alignment: .leading, spacing: 22) {
                    Card(title: "Status") {
                        HStack(spacing: 12) {
                            statusTile(ok: true, title: "Bereit für Assistenten", detail: "Kastellan läuft im Hintergrund, \(model.profiles.count) Profile.")
                            statusTile(ok: clientsConnected,
                                       title: clientsConnected ? "Claude verbunden" : "Noch kein Client aktiv",
                                       detail: clientsConnected ? "Zuletzt \(lastClientUse!.short). Jeder Zugriff wird protokolliert." : "Unter MCP-Clients ein Token ausstellen und eintragen.")
                        }
                        .padding(10)
                    }

                    Card(title: "Verbindungen im Profil \(model.selectedProfile?.name ?? "")",
                         trailing: AnyView(Button("Alle anzeigen") { navigate(.connections) }.buttonStyle(.plain).foregroundStyle(Theme.gold).kFont(.caption))) {
                        if model.profileConnections.isEmpty {
                            CardRow(last: true) {
                                Text("Noch keine Verbindung. Unter Verbindungen einen Hoster anlegen.").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(model.profileConnections.enumerated()), id: \.element.id) { index, c in
                            let entry = model.runtime.registry.entry(for: c.provider)
                            let health = model.health[c.id]
                            CardRow(last: index == model.profileConnections.count - 1) {
                                SymbolTile(symbol: "server.rack")
                                Text(c.label).kFont(.body, weight: .medium)
                                Spacer()
                                Text([entry?.displayName, c.settings["kas_login"]].compactMap { $0 }.joined(separator: " · "))
                                    .kFont(.callout).foregroundStyle(.secondary)
                                StatusDot(color: health == nil ? .gray : (health!.ok ? Theme.ok : Theme.warn))
                                Image(systemName: "chevron.right").kFont(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { navigate(.connections) }
                        }
                    }

                    if !model.pendingActions.isEmpty {
                        Card(title: "Offene Freigaben", trailing: AnyView(Button("Alle anzeigen") { navigate(.approvals) }.buttonStyle(.plain).foregroundStyle(Theme.gold).kFont(.caption))) {
                            ForEach(Array(model.pendingActions.prefix(4).enumerated()), id: \.element.id) { index, a in
                                CardRow(last: index == min(3, model.pendingActions.count - 1)) {
                                    SymbolTile(symbol: "checkmark.seal", color: Theme.warn)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.preview).kFont(.body, weight: .medium).lineLimit(1)
                                        Text("\(a.client) · \(model.connectionLabel(a.connectionID)) · \(a.createdAt.short)").kFont(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.canDecide(a) {
                                        Button("Verwerfen") { Task { await model.reject(a) } }
                                        Button("Freigeben") { Task { await model.approve(a) } }.buttonStyle(.borderedProminent).tint(Theme.gold)
                                    } else {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                        }
                    }

                    Card(title: "Letzte Aktivität", trailing: AnyView(Button("Protokoll öffnen") { navigate(.audit) }.buttonStyle(.plain).foregroundStyle(Theme.gold).kFont(.caption))) {
                        if recent.isEmpty {
                            CardRow(last: true) { Text("Noch keine Zugriffe.").foregroundStyle(.secondary) }
                        }
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, e in
                            CardRow(last: index == recent.count - 1) {
                                Text(e.timestamp.formatted(date: .omitted, time: .shortened)).kFont(.callout, monospacedDigit: true).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                                Text(e.client).kFont(.body, weight: .semibold)
                                Text(AuditEntryPresentation.label(tool: e.tool, capability: e.capability?.description)).foregroundStyle(.secondary)
                                if let target = e.target, !target.isEmpty {
                                    Text(target).kFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer()
                                Text(outcomeLabel(e.outcome)).kFont(.caption).foregroundStyle(outcomeColor(e.outcome))
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
        .task { load() }
        .onChange(of: model.pendingActions.count) { load() }
        .onChange(of: model.selectedProfileID) { load() }
    }

    private func statusTile(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: ok ? Theme.ok : .gray).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).kFont(.body, weight: .semibold)
                Text(detail).kFont(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.cardStroke))
    }

    private func load() {
        let all = (try? model.runtime.audit.entries(AuditFilter(limit: 400))) ?? []
        recent = Array(all.suffix(6).reversed())
    }

    private func outcomeLabel(_ o: AuditEntry.Outcome) -> String {
        switch o {
        case .ok, .confirmed: "Erledigt"
        case .pending: "Wartet"
        case .cancelled: "Verworfen"
        case .denied, .outOfScope: "Abgelehnt"
        case .unsupported: "Nicht möglich"
        case .error: "Fehler"
        }
    }

    private func outcomeColor(_ o: AuditEntry.Outcome) -> Color {
        switch o {
        case .ok, .confirmed: .secondary
        case .pending: Theme.warn
        default: Theme.bad
        }
    }
}

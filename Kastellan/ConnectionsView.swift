import SwiftUI
import KastellanCore

/// Bereich „Verbindungen“: Provider-Accounts des gewählten Profils, anlegen, prüfen, löschen.
struct ConnectionsView: View {
    let model: AppModel
    @State private var showAdd = false
    @State private var editing: Connection?
    @State private var pendingDelete: Connection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.profileConnections.isEmpty {
                    ContentUnavailableView("Keine Verbindungen im Profil \(model.selectedProfile?.name ?? "")",
                                           systemImage: "server.rack",
                                           description: Text("Legen Sie mit dem Plus oben rechts eine Verbindung zu einem Hoster an. Das Passwort landet im Schlüsselbund, nie in einer Datei."))
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 12) {
                        ForEach(model.profileConnections) { c in
                            ConnectionCard(model: model, connection: c,
                                           onEdit: { editing = c },
                                           onCheck: { Task { await model.checkHealth(c) } },
                                           onDelete: { pendingDelete = c })
                        }
                    }
                }

                Card(title: "Zuordnung: welche Verbindung ist wofür zuständig") {
                    AssignmentsSection(model: model)
                }
                Text("Beispiel: example.com mit Gruppe DNS → Cloudflare, *.example.com mit allen Ressourcen → All-Inkl. Tools ohne connection_id nutzen diese Regeln, genauere Muster und Regeln mit Ressourcen gewinnen. Was die Ressourcen bedeuten, steht unter Hilfe.")
                    .kFont(.caption).foregroundStyle(.secondary).padding(.top, -12).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("Verbindung anlegen", systemImage: "plus") }
                    .disabled(model.selectedProfile == nil)
            }
        }
        .sheet(isPresented: $showAdd) {
            if let ctx = model.selectedProfile {
                ConnectionEditor(model: model, profile: ctx, existing: nil)
            }
        }
        .sheet(item: $editing) { c in
            if let ctx = model.profiles.first(where: { $0.id == c.profileID }) {
                ConnectionEditor(model: model, profile: ctx, existing: c)
            }
        }
        .confirmationDialog("Verbindung \(pendingDelete?.label ?? "") löschen?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Löschen", role: .destructive) {
                if let c = pendingDelete { Task { try? await model.deleteConnection(c) } }
                pendingDelete = nil
            }
        } message: {
            Text("Secrets im Schlüsselbund, Rechte aller Clients und Zuordnungsregeln dieser Verbindung werden mit entfernt. Beim Hoster ändert sich nichts.")
        }
    }
}

/// Eine Verbindung als Karte, wie die Mail-Konten bei TorroMail. Klick klappt die Fähigkeiten des Providers auf.
struct ConnectionCard: View {
    let model: AppModel
    let connection: Connection
    let onEdit: () -> Void
    let onCheck: () -> Void
    let onDelete: () -> Void
    @State private var expanded = CommandLine.arguments.contains("--expand")

    var body: some View {
        let entry = model.runtime.registry.entry(for: connection.provider)
        let health = model.health[connection.id]
        let login = connection.settings.sorted { $0.key < $1.key }.map(\.value).first
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                SymbolTile(symbol: symbol(for: connection.provider))
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.label).kFont(.body, weight: .semibold)
                    Text([entry?.displayName ?? connection.provider, login].compactMap { $0 }.joined(separator: " · "))
                        .kFont(.caption).foregroundStyle(.secondary)
                    if let health {
                        Text("\(health.message) · \(health.checkedAt.short)").kFont(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer()
                StatusDot(color: health == nil ? .gray : (health!.ok ? Theme.ok : Theme.warn))
                Menu {
                    Button("Prüfen") { onCheck() }
                    Button("Bearbeiten") { onEdit() }
                    Divider()
                    Button("Löschen", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Image(systemName: "chevron.right").kFont(.caption).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }

            if expanded, let entry {
                Divider().overlay(Theme.cardStroke)
                CapabilityGrid(matrix: entry.capabilityMatrix)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardStroke))
        .contextMenu {
            Button("Prüfen") { onCheck() }
            Button("Bearbeiten") { onEdit() }
            Divider()
            Button("Löschen", role: .destructive) { onDelete() }
        }
    }

    private func symbol(for provider: String) -> String {
        switch provider {
        case "cloudflare": "cloud"
        case "hetzner": "server.rack"
        case "hostingde": "globe.europe.africa"
        case "mittwald": "shippingbox"
        case "hostinger": "h.square"
        case "namecheap": "n.square"
        default: "envelope"
        }
    }
}

/// Fähigkeiten eines Providers: je Ressource die unterstützten Aktionen, gruppiert.
struct CapabilityGrid: View {
    let matrix: CapabilityMatrix

    private static let actionLabels: [(Action, String)] = [
        (.list, "auflisten"), (.get, "lesen"), (.create, "anlegen"), (.update, "ändern"), (.setPassword, "Passwort"), (.delete, "löschen"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Was dieser Provider über Kastellan kann").kFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            ForEach(ResourceType.Group.allCases, id: \.self) { group in
                let members = group.members.filter { matrix.resources.contains($0) }
                if !members.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.rawValue).kFont(.caption2, weight: .semibold).foregroundStyle(Theme.gold)
                        ForEach(members, id: \.self) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(r.displayName).kFont(.caption).frame(width: 170, alignment: .leading)
                                HStack(spacing: 4) {
                                    ForEach(Self.actionLabels, id: \.0) { action, label in
                                        let ok = matrix.supports(Capability(r, action))
                                        Text(label)
                                            .kFont(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(ok ? Theme.gold.opacity(0.18) : Color.clear, in: Capsule())
                                            .overlay(Capsule().stroke(ok ? Theme.gold.opacity(0.5) : Theme.cardStroke))
                                            .foregroundStyle(ok ? Color.primary : Color.secondary.opacity(0.5))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let missing = ResourceType.allCases.filter { $0 != .connection && !matrix.resources.contains($0) }
            if !missing.isEmpty {
                Text("Nicht über diesen Provider: " + missing.map(\.displayName).joined(separator: ", "))
                    .kFont(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Anlegen oder Bearbeiten. Secrets nur schreiben, nie anzeigen.
struct ConnectionEditor: View {
    let model: AppModel
    let profile: KastellanProfile
    let existing: Connection?

    @Environment(\.dismiss) private var dismiss
    @State private var providerID: String
    @State private var label: String
    @State private var settings: [String: String]
    @State private var secrets: [String: String] = [:]
    @State private var saving = false
    @State private var errorText: String?

    init(model: AppModel, profile: KastellanProfile, existing: Connection?) {
        self.model = model
        self.profile = profile
        self.existing = existing
        let providers = model.runtime.registry.entries.keys.sorted()
        _providerID = State(initialValue: existing?.provider ?? providers.first ?? "")
        _label = State(initialValue: existing?.label ?? "")
        _settings = State(initialValue: existing?.settings ?? [:])
    }

    private var entry: AdapterRegistry.Entry? { model.runtime.registry.entry(for: providerID) }
    private var providers: [AdapterRegistry.Entry] { model.runtime.registry.entries.values.sorted { $0.displayName < $1.displayName } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Verbindung anlegen" : "Verbindung bearbeiten").kFont(.title2)
            Text("Profil \(profile.name)").foregroundStyle(.secondary)
            Form {
                if providers.isEmpty {
                    Text("Noch kein Adapter eingebaut. Der All-Inkl-Adapter kommt mit Phase 1.").foregroundStyle(.secondary)
                } else {
                    Picker("Provider", selection: $providerID) {
                        ForEach(providers, id: \.providerID) { Text($0.displayName).tag($0.providerID) }
                    }
                    .disabled(existing != nil)
                }
                TextField("Bezeichnung", text: $label, prompt: Text("z. B. All-Inkl privat"))
                if let entry {
                    ForEach(entry.settingKeys, id: \.key) { key in
                        TextField(key.label, text: Binding(get: { settings[key.key] ?? "" }, set: { settings[key.key] = $0 }),
                                  prompt: Text(key.placeholder.isEmpty ? "optional" : key.placeholder))
                    }
                    ForEach(entry.secretKeys, id: \.key) { key in
                        SecureField(key.label, text: Binding(get: { secrets[key.key] ?? "" }, set: { secrets[key.key] = $0 }),
                                    prompt: Text(existing == nil ? (key.placeholder.isEmpty ? "wird im Schlüsselbund abgelegt" : key.placeholder) : "leer lassen, um es zu behalten"))
                    }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            if let errorText { Text(errorText).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button(existing == nil ? "Anlegen und prüfen" : "Speichern und prüfen") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || entry == nil || label.trimmingCharacters(in: .whitespaces).isEmpty || missingSecrets)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var missingSecrets: Bool {
        guard existing == nil, let entry else { return false }
        return entry.secretKeys.contains { (secrets[$0.key] ?? "").isEmpty }
    }

    private func save() {
        saving = true
        let connection = Connection(id: existing?.id ?? UUID().uuidString.lowercased(), profileID: profile.id, provider: providerID,
                                    label: label.trimmingCharacters(in: .whitespaces),
                                    settings: settings.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty },
                                    createdAt: existing?.createdAt ?? Date())
        Task {
            do {
                try await model.saveConnection(connection, secrets: secrets)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}


/// Regeln der Domain-Zuordnung im gewählten Profil. Mehrere Ressourcen je Regel, Schnellwahl nach Gruppen.
struct AssignmentsSection: View {
    let model: AppModel
    @State private var pattern = ""
    @State private var selected: Set<ResourceType> = []
    @State private var connectionID: String?
    @State private var errorText: String?

    private static let selectable = ResourceType.allCases.filter { $0 != .connection }

    var body: some View {
        ForEach(model.profileAssignments) { a in
            CardRow {
                Text(a.domainPattern).kFont(.body, design: .monospaced)
                Text(Self.summary(a.resources)).foregroundStyle(.secondary).lineLimit(2)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Text(model.connectionLabel(a.connectionID))
                Spacer()
                Button(role: .destructive) { Task { await model.deleteAssignment(a) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        CardRow(last: true) {
            TextField("Domain-Muster", text: $pattern, prompt: Text("Domain oder *.domain oder *"))
                .textFieldStyle(.roundedBorder).frame(minWidth: 200)
            Menu {
                Button("Alle Ressourcen") { selected = [] }
                Divider()
                ForEach(ResourceType.Group.allCases, id: \.self) { group in
                    Button("Gruppe \(group.rawValue): \(group.members.map(\.displayName).joined(separator: ", "))") {
                        selected.formUnion(group.members)
                    }
                }
                Divider()
                ForEach(Self.selectable, id: \.self) { r in
                    Toggle(isOn: Binding(get: { selected.contains(r) }, set: { on in if on { selected.insert(r) } else { selected.remove(r) } })) {
                        Text("\(r.displayName) (\(r.rawValue))")
                    }
                }
            } label: {
                Text(Self.summary(Array(selected))).lineLimit(1)
            }
            .frame(minWidth: 180, maxWidth: 320)
            Picker("Verbindung", selection: Binding(get: { connectionID ?? model.profileConnections.first?.id }, set: { connectionID = $0 })) {
                ForEach(model.profileConnections) { Text($0.label).tag(Optional($0.id)) }
            }
            .labelsHidden()
            Button("Hinzufügen") { add() }
                .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty || (connectionID ?? model.profileConnections.first?.id) == nil)
        }
        if let errorText { CardRow(last: true) { Text(errorText).foregroundStyle(.red).kFont(.caption) } }
    }

    /// „alle Ressourcen“, ein Gruppenname, wenn genau die Gruppe gewählt ist, sonst die Namen.
    static func summary(_ resources: [ResourceType]) -> String {
        if resources.isEmpty { return "alle Ressourcen" }
        let set = Set(resources)
        if let g = ResourceType.Group.allCases.first(where: { Set($0.members) == set }) { return "Gruppe \(g.rawValue)" }
        return resources.sorted { $0.rawValue < $1.rawValue }.map(\.displayName).joined(separator: ", ")
    }

    private func add() {
        guard let ctx = model.selectedProfile, let cid = connectionID ?? model.profileConnections.first?.id else { return }
        let a = Assignment(profileID: ctx.id, domainPattern: pattern.trimmingCharacters(in: .whitespaces).lowercased(),
                           resources: Self.selectable.filter { selected.contains($0) }, connectionID: cid)
        Task {
            do { try await model.saveAssignment(a); pattern = ""; selected = []; errorText = nil } catch { errorText = error.localizedDescription }
        }
    }
}

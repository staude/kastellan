import SwiftUI
import KastellanCore

/// Bereich „Rechte“: Policy je Client-Token und Verbindung im gewählten Profil.
struct PermissionsView: View {
    let model: AppModel
    @State private var tokenID: String?
    @State private var connectionID: String?
    @State private var policy = Policy()
    @State private var domains = ""
    @State private var excludes = ""
    @State private var recordTypes = ""
    @State private var confirmExtra = ""
    @State private var maxWrites = ""
    @State private var saved = false
    @State private var errorText: String?

    private var token: ClientToken? { model.profileTokens.first { $0.id == tokenID } ?? model.profileTokens.first }
    private var connection: Connection? { model.profileConnections.first { $0.id == connectionID } ?? model.profileConnections.first }
    private var resources: [ResourceType] {
        guard let connection, let matrix = model.runtime.registry.capabilityMatrix(for: connection.provider) else { return [] }
        return ResourceType.allCases.filter { matrix.resources.contains($0) }
    }

    var body: some View {
        Form {
            Section("Client und Verbindung") {
                Picker("Client-Token", selection: Binding(get: { token?.id }, set: { tokenID = $0 })) {
                    ForEach(model.profileTokens) { Text($0.client).tag(Optional($0.id)) }
                }
                Picker("Verbindung", selection: Binding(get: { connection?.id }, set: { connectionID = $0 })) {
                    ForEach(model.profileConnections) { Text($0.label).tag(Optional($0.id)) }
                }
                if model.profileTokens.isEmpty {
                    Text("Erst im Bereich MCP ein Token für diesen Profil ausstellen.").foregroundStyle(.secondary)
                }
                if model.profileConnections.isEmpty {
                    Text("Erst eine Verbindung anlegen.").foregroundStyle(.secondary)
                }
            }
            if token != nil, connection != nil {
                Section("Stufen pro Ressource") {
                    ForEach(resources, id: \.self) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(r.explanation).kFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Picker("\(r.displayName) (\(r.rawValue))", selection: Binding(get: { policy.level(for: r) }, set: { policy.levels[r] = $0 })) {
                                ForEach(PermissionLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            if policy.level(for: r) >= .write {
                                Toggle("Anlegen und Ändern nur mit Freigabe", isOn: Binding(
                                    get: { writeNeedsConfirmation(r) },
                                    set: { setWriteConfirmation(r, $0) }))
                                .kFont(.caption)
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    Text("none: unsichtbar. read: auflisten und lesen. write: anlegen, ändern, Passwort setzen. manage: zusätzlich löschen und geschützte DNS-Records (MX, NS, SOA). Löschen und geschützte Records laufen immer über eine Freigabe; für Anlegen und Ändern lässt sich das je Ressource zuschalten.")
                        .kFont(.caption).foregroundStyle(.secondary)
                }
                Section("Geltungsbereich") {
                    TextField("Domain-Muster (kommagetrennt, * für alles, *.domain für Subdomains)", text: $domains, prompt: Text("example.com, *.firma.example"))
                    TextField("Ausschlüsse (Adressen oder Hosts)", text: $excludes, prompt: Text("user@firma.example"))
                    TextField("Erlaubte DNS-Record-Typen (leer = alle außer MX, NS, SOA)", text: $recordTypes, prompt: Text("A, AAAA, CNAME, TXT, CAA"))
                }
                Section("Bestätigung und Limits") {
                    TextField("Zusätzliche Bestätigungen (resource:action)", text: $confirmExtra, prompt: Text("mailbox:update"))
                    TextField("Schreibaktionen pro Stunde (leer = unbegrenzt)", text: $maxWrites, prompt: Text("30"))
                    Toggle("Agent darf eigene Aktionen selbst freigeben (agent_may_confirm)", isOn: $policy.agentMayConfirm)
                    Toggle("Generierte Passwörter im Tool-Ergebnis zeigen (sonst nur Schlüsselbund)", isOn: $policy.revealGeneratedPasswords)
                }
                Section {
                    HStack {
                        if saved { Text("Gespeichert.").foregroundStyle(.green) }
                        if let errorText { Text(errorText).foregroundStyle(.red) }
                        Spacer()
                        Button("Speichern") { save() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Rechte")
        .task { await load() }
        .onChange(of: tokenID) { Task { await load() } }
        .onChange(of: connectionID) { Task { await load() } }
        .onChange(of: model.selectedProfileID) { tokenID = nil; connectionID = nil; Task { await load() } }
    }

    private func load() async {
        saved = false
        guard let token, let connection, let ctx = model.selectedProfile else { return }
        policy = (try? await model.runtime.policies.policy(profile: ctx.slug, client: token.client, connectionID: connection.id)) ?? Policy()
        domains = policy.domainPatterns.joined(separator: ", ")
        excludes = policy.excludedTargets.joined(separator: ", ")
        recordTypes = policy.scopes.dnsRecordTypes.joined(separator: ", ")
        confirmExtra = policy.confirmExtra.joined(separator: ", ")
        maxWrites = policy.maxWritesPerHour.map(String.init) ?? ""
    }

    private func save() {
        guard let token, let connection, let ctx = model.selectedProfile else { return }
        var p = policy
        p.domainPatterns = split(domains)
        p.excludedTargets = split(excludes)
        p.scopes.dnsRecordTypes = split(recordTypes).map { $0.uppercased() }
        p.confirmExtra = split(confirmExtra)
        p.maxWritesPerHour = Int(maxWrites.trimmingCharacters(in: .whitespaces))
        Task {
            do {
                try await model.runtime.policies.set(p, profile: ctx.slug, client: token.client, connectionID: connection.id)
                policy = p
                saved = true
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private static let writeActions: [Action] = [.create, .update, .setPassword]

    private func writeNeedsConfirmation(_ r: ResourceType) -> Bool {
        let set = Set(split(confirmExtra))
        return set.contains("\(r.rawValue):create")
    }

    private func setWriteConfirmation(_ r: ResourceType, _ on: Bool) {
        var set = Set(split(confirmExtra))
        for a in Self.writeActions {
            let key = "\(r.rawValue):\(a.rawValue)"
            if on { set.insert(key) } else { set.remove(key) }
        }
        confirmExtra = set.sorted().joined(separator: ", ")
    }

    private func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

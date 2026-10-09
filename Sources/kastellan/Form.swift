import Foundation
import KastellanCore

/// Dialog mit Eingabefeldern. Pfeiltasten wählen das Feld, Tippen ändert es, Enter auf „Speichern“
/// speichert, Escape bricht ab.
@MainActor
protocol Form: AnyObject {
    var title: String { get }
    func handle(_ key: Key, tui: TUI) async
    func lines(width: Int) -> [Line]
}

/// Verbindung anlegen oder bearbeiten: Provider, Bezeichnung, Einstellungen, Zugangsdaten.
@MainActor
final class ConnectionForm: Form {
    struct Field {
        enum Kind { case provider, label, setting(SettingKey), secret(SettingKey), save }
        var kind: Kind
        var value: String
    }

    let profile: KastellanProfile
    let existing: Connection?
    let providers: [AdapterRegistry.Entry]
    var providerIndex: Int
    var fields: [Field] = []
    var focus = 0
    var error: String?

    var title: String { existing == nil ? "Verbindung anlegen" : "Verbindung bearbeiten" }

    init(tui: TUI, profile: KastellanProfile, existing: Connection?) {
        self.profile = profile
        self.existing = existing
        providers = tui.runtime.registry.entries.values.sorted { $0.displayName < $1.displayName }
        providerIndex = providers.firstIndex { $0.providerID == existing?.provider } ?? 0
        rebuild(label: existing?.label ?? "", settings: existing?.settings ?? [:])
        focus = existing == nil ? 0 : 1
    }

    var entry: AdapterRegistry.Entry { providers[providerIndex] }

    func rebuild(label: String, settings: [String: String]) {
        fields = [Field(kind: .provider, value: ""), Field(kind: .label, value: label)]
        fields += entry.settingKeys.map { Field(kind: .setting($0), value: settings[$0.key] ?? "") }
        fields += entry.secretKeys.map { Field(kind: .secret($0), value: "") }
        fields.append(Field(kind: .save, value: ""))
    }

    func handle(_ key: Key, tui: TUI) async {
        error = nil
        switch key {
        case .escape:
            tui.modal = nil
        case .up, .backTab:
            focus = max(0, focus - 1)
        case .down, .tab:
            focus = min(fields.count - 1, focus + 1)
        case .left, .right:
            if case .provider = fields[focus].kind, existing == nil {
                providerIndex = (providerIndex + (key == .right ? 1 : providers.count - 1)) % providers.count
                rebuild(label: fields[1].value, settings: [:])
            }
        case .enter:
            if case .save = fields[focus].kind { await save(tui) } else { focus = min(fields.count - 1, focus + 1) }
        case .ctrl("s"):
            await save(tui)
        case .ctrl("r"):
            // Öffentliche IPv4 ermitteln, wenn das Feld es anbietet (Namecheap Client-IP).
            if case .setting(let k) = fields[focus].kind, k.detect == .publicIPv4 {
                do { fields[focus].value = try await PublicIPv4.detect() } catch { self.error = error.localizedDescription }
            }
        case .backspace:
            if editable(focus) { fields[focus].value = String(fields[focus].value.dropLast()) }
        case .char(let c):
            if editable(focus) { fields[focus].value.append(c) }
        default:
            break
        }
    }

    func editable(_ i: Int) -> Bool {
        switch fields[i].kind {
        case .label, .setting, .secret: true
        default: false
        }
    }

    func save(_ tui: TUI) async {
        let label = fields[1].value.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { error = "Bezeichnung fehlt."; focus = 1; return }
        var settings: [String: String] = [:]
        var secrets: [String: String] = [:]
        for f in fields {
            switch f.kind {
            case .setting(let k):
                let v = f.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { settings[k.key] = v }
            case .secret(let k):
                let v = f.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { secrets[k.key] = v }
            default: break
            }
        }
        if existing == nil, let missing = entry.secretKeys.first(where: { secrets[$0.key] == nil }) {
            error = "\(missing.label) fehlt."
            return
        }
        let connection = Connection(id: existing?.id ?? UUID().uuidString.lowercased(), profileID: profile.id, provider: entry.providerID,
                                    label: label, settings: settings, createdAt: existing?.createdAt ?? Date())
        do {
            try await tui.runtime.connections.upsert(connection)
            for (k, v) in secrets { try await tui.runtime.secrets.set(connectionID: connection.id, key: k, value: v) }
        } catch {
            self.error = error.localizedDescription
            return
        }
        tui.modal = nil
        await tui.reload()
        tui.checkHealth(connection)
    }

    func lines(width: Int) -> [Line] {
        var out: [Line] = []
        for (i, f) in fields.enumerated() {
            let focused = i == focus
            let marker = focused ? "›" : " "
            switch f.kind {
            case .provider:
                let text = existing == nil ? "‹ \(entry.displayName) ›" : entry.displayName
                out.append(Line("\(marker) Provider            ", focused ? Style.gold : Style.muted).adding(text, focused ? Style.selected : ""))
            case .label:
                out.append(field(marker, "Bezeichnung", f.value, focused, placeholder: "z. B. \(entry.displayName) privat"))
            case .setting(let k):
                var line = field(marker, k.label, f.value, focused, placeholder: k.placeholder.isEmpty ? "optional" : k.placeholder)
                if k.detect == .publicIPv4, focused { line.add("  Strg+R ermitteln", Style.muted) }
                out.append(line)
            case .secret(let k):
                let shown = f.value.isEmpty ? "" : String(repeating: "•", count: min(f.value.count, 24))
                out.append(field(marker, k.label, shown, focused,
                                 placeholder: existing == nil ? (k.placeholder.isEmpty ? "wird sicher abgelegt" : k.placeholder) : "leer lassen, um es zu behalten"))
            case .save:
                out.append(Line())
                out.append(Line("  [ Speichern und prüfen ]", focused ? Style.selected : Style.gold))
            }
        }
        out.append(Line())
        if let error { out.append(Line(error, Style.red)) }
        out.append(Line("↑↓ Feld · ←→ Provider · Enter weiter · Strg+S speichern · Esc abbrechen", Style.muted))
        return out
    }

    private func field(_ marker: String, _ label: String, _ value: String, _ focused: Bool, placeholder: String) -> Line {
        var line = Line("\(marker) \(label.padded(20))", focused ? Style.gold : Style.muted)
        if value.isEmpty {
            line.add(placeholder, Style.dim)
        } else {
            line.add(value, focused ? Style.bold : "")
        }
        if focused { line.add("▏", Style.gold) }
        return line
    }
}

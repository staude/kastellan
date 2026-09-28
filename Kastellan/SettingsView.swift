import SwiftUI
import KastellanCore

/// Bereich „Einstellungen“ nach TorroMail-Vorbild.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let settingsModel: AppModel
    let navigate: (AppModel.Section) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                Card {
                    CardRow(last: true) {
                        Text("Beim Anmelden starten"); Spacer()
                        Toggle("Beim Anmelden starten", isOn: $settings.launchAtLogin).toggleStyle(.switch).labelsHidden()
                    }
                }
                caption(settings.launchAtLoginError ?? "Kastellan und der MCP-Server sind dann sofort nach der Anmeldung verfügbar.")

                Card(title: "Wo Kastellan auftaucht") {
                    CardRow { Text("In der Menüleiste anzeigen"); Spacer(); Toggle("In der Menüleiste anzeigen", isOn: $settings.showInMenuBar).toggleStyle(.switch).labelsHidden() }
                    CardRow(last: true) { Text("Im Dock behalten"); Spacer(); Toggle("Im Dock behalten", isOn: $settings.keepInDock).toggleStyle(.switch).labelsHidden() }
                }
                caption("Kastellan bedient Assistenten so oder so. Sind beide aus, ist die App nur sichtbar, solange dieses Fenster offen ist. Ein Klick auf Kastellan im Finder oder Launchpad holt das Fenster zurück.")

                Card(title: "Schrift") {
                    CardRow(last: true) {
                        Text("Schriftgröße")
                        Spacer()
                        Button { settings.decreaseText() } label: { Image(systemName: "textformat.size.smaller") }.disabled(!settings.canDecreaseText)
                        Text("\(Int((settings.textScale * 100).rounded())) %").monospacedDigit().frame(width: 60)
                        Button { settings.increaseText() } label: { Image(systemName: "textformat.size.larger") }.disabled(!settings.canIncreaseText)
                        Button("Standard") { settings.resetText() }
                    }
                }
                caption("Auch über das Menü Darstellung: ⌘ + größer, ⌘ - kleiner, ⌘ 0 Standard. Gilt für Fenster und Menüleisten-Popover.")

                CredentialSettingsView(model: settingsModel)
                caption("Gilt für alle Zugänge, die Kastellan im gewählten Profil erzeugt: Postfächer, FTP, Datenbanken, Verzeichnisschutz, Server-Root. Bitwarden und 1Password schreibt nur die App; Zugänge aus Claude warten so lange sicher im Schlüsselbund.")

                Card(title: "MCP-Clients") {
                    CardRow(last: true) {
                        Button("Assistenten einrichten …") { navigate(.mcp) }
                        Spacer()
                    }
                }
                caption("Tokens, Einträge für Claude Code und Claude Desktop sowie die Rechte je Client liegen in den Bereichen MCP-Clients und Rechte.")

                UpdatesCard()

                Card(title: "Telemetrie") {
                    CardRow(last: true) {
                        Text("Fehler an telemetrie.staude.cc melden"); Spacer()
                        Toggle("Fehler melden", isOn: $settings.telemetryEnabled).toggleStyle(.switch).labelsHidden()
                    }
                }
                caption("Standardmäßig aus. Eingeschaltet werden Fehlertyp, Meldung, Komponente, Provider und Aktion gemeldet. Nie Passwörter, Tokens oder Parameter. Nicht zustellbare Meldungen warten im Postausgang und werden beim nächsten Start nachgeliefert. Die Änderung gilt für neu gestartete MCP-Server sofort, für die App nach dem nächsten Start.")

                Card(title: "Dateien") {
                    CardRow(last: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppPaths.home.path).kFont(.callout, design: .monospaced).textSelection(.enabled)
                            Text("Profile, Verbindungen (ohne Secrets), Token-Hashes, Rechte, Zuordnung, Freigaben, Protokoll. Secrets liegen im Schlüsselbund.").kFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.home]) }
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.background)
    }

    private func caption(_ text: String) -> some View {
        Text(text).kFont(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing).padding(.top, -12)
    }
}

/// Updates nach TorroMail-Vorbild: automatisch alle 24 Stunden, oder sofort per Knopf.
private struct UpdatesCard: View {
    @State private var updater = UpdaterController.shared

    var body: some View {
        Card(title: "Updates") {
            CardRow {
                Text("Automatisch nach Updates suchen"); Spacer()
                Toggle("Automatisch nach Updates suchen", isOn: $updater.automaticallyChecksForUpdates)
                    .toggleStyle(.switch).labelsHidden().disabled(!updater.isAvailable)
            }
            CardRow(last: true) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    Text(statusText).kFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Jetzt suchen") { updater.checkForUpdates() }.disabled(!updater.isAvailable)
            }
        }
        Text(updater.isAvailable
             ? "Kastellan prüft beim Start und danach alle 24 Stunden, ob es eine neue Version gibt. Updates laden im Hintergrund und werden beim nächsten Beenden installiert."
             : "Dieser Build aktualisiert sich nicht selbst (Entwickler-Build). Neue Versionen gibt es unter github.com/staude/kastellan/releases.")
            .kFont(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing).padding(.top, -12)
    }

    private var statusText: String {
        guard updater.isAvailable else { return "Automatische Updates nicht verfügbar" }
        guard let date = updater.lastUpdateCheckDate else { return "Noch nicht geprüft" }
        return "Zuletzt geprüft: \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

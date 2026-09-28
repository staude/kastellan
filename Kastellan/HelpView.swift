import SwiftUI
import KastellanCore

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card(title: "Der Name") {
                    CardRow(last: true) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kastellan").kFont(.body, weight: .semibold)
                            Text("Der Kastellan war der Verwalter einer Burg im Auftrag des Burgherrn: Er hielt die Schlüssel, bewachte die Tore, führte Buch über Vorräte und Zugänge und ließ niemanden ohne Erlaubnis hinein. Genau das macht diese App für Ihre Hoster: Sie verwahrt die Zugänge, gibt Assistenten nur die vereinbarten Rechte, protokolliert jeden Zugriff und holt bei allem Heiklen erst Ihre Freigabe ein. Im Namen steckt außerdem KAS, die Verwaltungsoberfläche von All-Inkl, mit der das Projekt begonnen hat.")
                                .kFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Card(title: "Einrichtung Schritt für Schritt") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        CardRow(last: i == steps.count - 1) {
                            Text("\(i + 1)").kFont(.callout, weight: .bold).foregroundStyle(Theme.navy)
                                .frame(width: 26, height: 26).background(Theme.gold, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.0).kFont(.body, weight: .medium)
                                Text(step.1).kFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Card(title: "Ressourcen: was die Begriffe bedeuten") {
                    ForEach(Array(ResourceType.Group.allCases.enumerated()), id: \.offset) { gi, group in
                        ForEach(Array(group.members.enumerated()), id: \.offset) { ri, r in
                            CardRow(last: gi == ResourceType.Group.allCases.count - 1 && ri == group.members.count - 1) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(r.displayName).kFont(.body, weight: .medium)
                                        Text(r.rawValue).kFont(.caption, design: .monospaced).foregroundStyle(.tertiary)
                                        Text(group.rawValue).kFont(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Theme.background, in: Capsule()).foregroundStyle(.secondary)
                                    }
                                    Text(r.explanation).kFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                Card(title: "Domain, Subdomain, DNS-Zone, DNS-Record") {
                    CardRow(last: true) {
                        Text("Domain und Subdomain sind das Hosting: welcher Ordner auf dem Webspace unter example.de oder app.example.de erreichbar ist. DNS-Zone und DNS-Record sind die Namensauflösung: die Zone ist die Liste aller Einträge einer Domain beim Nameserver, ein Record ein einzelner Eintrag darin. Beides kann bei verschiedenen Anbietern liegen, etwa Webspace und Mail bei All-Inkl, DNS bei Cloudflare. Genau dafür ist die Zuordnung unter Verbindungen da.")
                            .kFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Card(title: "Rechtestufen") {
                    ForEach(Array(levels.enumerated()), id: \.offset) { i, l in
                        CardRow(last: i == levels.count - 1) {
                            Text(l.0).kFont(.body, design: .monospaced).frame(width: 90, alignment: .leading)
                            Text(l.1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Card(title: "Kommandozeile") {
                    CardRow(last: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("/Applications/Kastellan.app/Contents/MacOS/kastellan-mcp doctor").kFont(.callout, design: .monospaced).textSelection(.enabled)
                            Text("Zeigt Profile, Verbindungen, Tokens und ob der Schlüsselbund für das MCP-Binary lesbar ist.").kFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Card(title: "Telemetrie") {
                    CardRow(last: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Standardmäßig aus. Eingeschaltet gehen Fehler an telemetrie.staude.cc (GlitchTip): Fehlertyp, Meldung, Komponente, Provider, Aktion. Keine Passwörter, Tokens oder Parameter.").kFont(.caption).foregroundStyle(.secondary)
                            Text("Einschalten in den Einstellungen oder mit KASTELLAN_TELEMETRY=on. Eigene Instanz über KASTELLAN_SENTRY_DSN; KASTELLAN_TELEMETRY=off schaltet immer ab.").kFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Card(title: "Dateien") {
                    CardRow(last: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppPaths.home.path).kFont(.callout, design: .monospaced).textSelection(.enabled)
                            Text("profiles.json, connections.json (ohne Secrets), tokens.json (nur Hashes), policies/, pending/, audit.jsonl, health.jsonl. Secrets liegen im Schlüsselbund.").kFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.background)
    }

    private let steps = [
        ("Verbindung anlegen", "Unter Verbindungen den Hoster wählen, Login und Passwort eintragen. Das Passwort landet im Schlüsselbund."),
        ("hosting.de anbinden", "Im Kundenpanel von hosting.de einen API-Key mit den benötigten Rechten erzeugen und hier als API-Key eintragen. Die Unterkonto-ID ist nur nötig, wenn die Verbindung im Namen eines Unterkontos arbeiten soll; die API-Basis bleibt leer, außer für http.net. Der Health-Check zählt die DNS-Zonen."),
        ("Client eintragen", "Unter MCP-Clients bei Claude Code oder Claude Desktop auf Eintragen. Ein Token wird ausgestellt und der Eintrag geschrieben."),
        ("Rechte setzen", "Unter Rechte pro Client und Verbindung die Stufen und Domain-Muster festlegen. Änderungen wirken sofort."),
        ("Freigaben erteilen", "Löschen und andere heikle Aktionen landen unter Freigaben. Erst nach Klick auf Freigeben wird ausgeführt."),
        ("Löschen und Umbenennen", "Verbindungen über das Menü ⋯ in der Zeile oder per Rechtsklick. Profile über das Menü ⋯ neben der Profil-Auswahl, sobald keine Verbindungen und Tokens mehr darin liegen."),
        ("Passwort-Ablage wählen", "Unter Einstellungen je Profil festlegen, wohin erzeugte Passwörter gehen: nur ins Ergebnis, in den Schlüsselbund, nach Bitwarden (Ordner oder Organisation und Sammlung) oder 1Password (Tresor). Bitwarden dort entsperren; Zugänge aus Claude warten bis dahin im Schlüsselbund."),
        ("Mittwald anbinden", "Im mStudio unter Profil → API-Tokens einen Token mit Rolle api_write und Ablaufdatum erzeugen und hier eintragen. Der Token erbt die Rechte Ihres Nutzers; Kunden oder Mitarbeiter laden Sie im mStudio mit Rolle ein, jede Person nutzt einen eigenen Token als eigene Verbindung. Projekt-ID nur setzen, wenn eine Verbindung genau ein Projekt bedienen soll."),
        ("Hostinger anbinden", "Im hPanel unter Profil → API einen Token mit Ablaufdatum erzeugen und hier eintragen. Der Token hat alle Rechte Ihres Kontos, Kastellan grenzt über Rechte und Zuordnung ein. Die API erlaubt 90 Aufrufe pro Minute; Kastellan wartet bei Überschreitung kurz."),
        ("Aktualisieren", "Kastellan sucht beim Start und danach alle 24 Stunden nach einer neuen Version, lädt sie im Hintergrund und installiert sie beim nächsten Beenden. Abschalten und sofort suchen unter Einstellungen → Updates oder im App-Menü „Nach Updates suchen …“."),
        ("Zuordnung pflegen", "Unter Verbindungen festlegen, welche Verbindung für welche Domain und Ressource zuständig ist. Dann kommen Tools ohne connection_id aus."),
    ]

    private let levels = [
        ("none", "Ressource ist für den Client unsichtbar."),
        ("read", "Auflisten und lesen."),
        ("write", "Anlegen, ändern, Passwort setzen."),
        ("manage", "Zusätzlich löschen und geschützte DNS-Records (MX, NS, SOA), jeweils mit Freigabe."),
    ]
}

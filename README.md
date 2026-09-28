# Kastellan

Kastellan verwaltet Hoster im Auftrag: Postfächer, Weiterleitungen, DNS-Records, Datenbanken, Cronjobs und Server bei mehreren Anbietern, hinter einem einheitlichen Ressourcen- und Rechtemodell. Eine macOS-App verwahrt Verbindungen, Zugangsdaten und Rechte. Ein eingebetteter MCP-Server stellt die erlaubten Aktionen Claude und anderen Agenten zur Verfügung. Heikle Aktionen wie Löschen laufen über Vorbereiten und Freigeben in der App, jeder Zugriff landet im Protokoll.

Vorbild ist [TorroMail](https://github.com/mahype/TorroMail), übertragen von Mailkonten auf Hosting-APIs.

## Unterstützte Anbieter

| Anbieter | Zugang | Schwerpunkte |
|---|---|---|
| All-Inkl (KAS) | KAS-Login und Passwort | Domains, Subdomains, DNS, Postfächer, Weiterleitungen, Autoresponder, DKIM, FTP, Datenbanken, Cronjobs, Verzeichnisschutz |
| Cloudflare | API-Token | DNS-Zonen und Records, Email Routing, Zertifikate lesend |
| Hetzner Cloud | Projekt-Token | DNS, Server mit Power-Aktionen, SSH-Keys, Firewalls lesend |
| hosting.de | API-Key | DNS, Domains, Mail, Webspace-Nutzer, Datenbanken, Cronjobs, Verzeichnisschutz, Zertifikate, Server |
| Mittwald (mStudio) | API-Token | Server, Domains, Ingress, DNS, Mail, MySQL, SSH/SFTP, Cronjobs, Zertifikate, Einladungen |
| Hostinger | API-Token | Domains, DNS mit Probelauf, VPS, Firewalls, Mail, Webhosting-Datenbanken und Cronjobs |

Welche Aktionen ein Anbieter tatsächlich kann, zeigt die App je Verbindung an. Was ein Anbieter nicht per API anbietet, bietet Kastellan dort auch nicht an.

## Installation

Die fertige App liegt unter [Releases](../../releases): DMG laden, `Kastellan.app` nach Programme ziehen, starten. Die App ist mit Developer ID signiert und von Apple notarisiert. Voraussetzung ist macOS 14 oder neuer.

Ab Version 0.2.0 aktualisiert sich Kastellan selbst: beim Start und danach alle 24 Stunden prüft die App, ob es eine neue Version gibt, lädt sie im Hintergrund und installiert sie beim nächsten Beenden. Abschalten lässt sich das unter Einstellungen → Updates.

Danach in der App:
1. Unter Verbindungen den ersten Hoster anlegen. Zugangsdaten landen im macOS-Schlüsselbund.
2. Unter Rechte festlegen, was ein Assistent je Verbindung darf: keine, lesen, schreiben oder verwalten.
3. Unter MCP-Clients einen Token für Claude Code oder Claude Desktop ausstellen und die Konfiguration schreiben lassen.

## MCP-Anbindung

Der Server liegt unter `Kastellan.app/Contents/MacOS/kastellan-mcp`. Die App schreibt den Eintrag auf Knopfdruck, von Hand sieht er so aus:

```json
"kastellan": {
  "type": "stdio",
  "command": "/Applications/Kastellan.app/Contents/MacOS/kastellan-mcp",
  "env": { "KASTELLAN_TOKEN": "<Token aus der App>" }
}
```

Ohne gültigen Token startet der Server, meldet aber keine Tools. `kastellan-mcp doctor` zeigt Profile, Verbindungen und ob der Schlüsselbund lesbar ist.

## Datenschutz

- Zugangsdaten liegen ausschließlich im Schlüsselbund, nie in Dateien oder im Protokoll.
- Erzeugte Passwörter gehen je Profil wahlweise nur ins Ergebnis, in den Schlüsselbund, nach Bitwarden oder nach 1Password.
- Fehler-Telemetrie ist standardmäßig aus. Eingeschaltet meldet die App Fehlertyp, Meldung, Komponente, Provider und Aktion an die GlitchTip-Instanz des Projekts oder an eine eigene DSN (`KASTELLAN_SENTRY_DSN`), nie Passwörter, Tokens oder Parameter.

## Aus dem Quellcode bauen

```
Kastellan/                 SwiftUI-App (Verbindungen, Rechte, Freigaben, Protokoll, Einstellungen)
kastellan-mcp/             MCP-Server (stdio), eingebettet in Kastellan.app/Contents/MacOS
Packages/KastellanCore/    Swift Package: Ressourcenmodell, Rechte, Audit, Adapter je Anbieter
KastellanTests/            App-Tests
tools/                     Build-, Release- und Probe-Skripte
project.yml                XcodeGen-Definition, das .xcodeproj wird daraus erzeugt
```

Voraussetzungen: Xcode 16 oder neuer (Swift 6) und [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./setup.sh
(cd Packages/KastellanCore && swift test)
xcodebuild -project Kastellan.xcodeproj -scheme Kastellan -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Für einen signierten Build `DEVELOPMENT_TEAM` in `project.yml` auf das eigene Team setzen und `tools/build-and-install.sh` ausführen. App und MCP-Server müssen mit demselben Team signiert sein, sonst können sie die gemeinsamen Schlüsselbund-Einträge nicht lesen. `tools/package-release.sh` baut, signiert mit Developer ID, notarisiert, packt DMG und ZIP und erzeugt den Update-Feed `appcast.xml`. Dafür braucht es den Sparkle-Schlüssel des Projekts im Schlüsselbund; wer selbst verteilt, legt mit `generate_keys --account kastellan` einen eigenen an und trägt dessen öffentlichen Teil als `SUPublicEDKey` in `Kastellan/Info.plist` ein.

## Lizenz

MIT, siehe [LICENSE](LICENSE).

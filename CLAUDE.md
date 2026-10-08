# Kastellan — Projekt-Profil für Claude

Diese Datei gilt für Claude-Sitzungen in diesem Projekt. Sie ergänzt die globale Vault-CLAUDE.md und die Projekt-Standards im Vault (`00 Profil/Projekt-Standards.md`).

## Was ist das?

macOS-Menüleisten-App mit eingebettetem MCP-Server, die Hosting-APIs (All-Inkl KAS, Mittwald, Hetzner DNS, Cloudflare, Namecheap, Mailcow, Panels) hinter einem einheitlichen Ressourcen- und Rechtemodell verwaltet. Vorbild TorroMail. Konzept und Entscheidungen: Vault `02 Projekte/Kastellan — Konzept.md`. Das Konzept ist die Quelle für Ressourcenmodell, Rechtestufen und Phasenplan; bei Abweichungen erst das Konzept anpassen, dann den Code.

## Arbeitsablauf

1. Erst diskutieren, dann umsetzen. Neue Adapter, neue Ressourcen, Änderungen am Rechtemodell werden mit Frank abgestimmt.
2. Ein GitHub-Issue pro Aufgabe im Repo `staude/kastellan`, Labels `feature`, `bug`, `docs`, `chore`, `adapter`.
3. Ein Branch pro Issue: `feature/12-kas-mailbox`, `fix/12-flood-delay`.
4. Pull Request nach `main` mit `Closes #12`. Für Phase 0 und 1 (Entscheidung 2026-09-06) merged Claude per Squash selbst, Frank reviewt den Stand auf `main` am Ende jeder Phase. Ab Phase 2 gilt wieder: Claude öffnet, Frank merged.
5. Ticketnummer in Commit-Subject (`#12 feat: KAS-Adapter mailbox_list`), CHANGELOG-Eintrag und Vault-Notiz.

## Architektur-Regeln

- **Drei Schichten, klare Grenzen.** `KastellanCore` kennt keine UI und kein MCP-SDK. `kastellan-mcp` ist eine dünne Schicht über dem Core. `Kastellan` (App) besitzt Verbindungen, Secrets, Rechte und Freigaben.
- **Secrets nur über die App in den Schlüsselbund.** Kein MCP-Tool schreibt Provider-Credentials. Teilen zwischen App und MCP-Binary läuft über die ACL der Einträge (beide Programme vertrauenswürdig), nicht über Keychain-Access-Groups: das eingebettete Kommandozeilen-Binary hat kein Provisioning-Profil und würde mit diesem Entitlement vom System sofort beendet. Beide Targets bleiben mit demselben Team signiert.
- **Adapter implementieren nur, was der Provider kann.** Ein Adapter erfüllt die Protokolle pro Ressourcentyp (`MailboxAdapter`, `DnsRecordAdapter`, ...) und deklariert seine Capability-Matrix statisch. Provider-Spezifisches kommt in `extra`, nie stillschweigend in Kernfelder.
- **Effektives Recht = Policy ∩ Capability ∩ Scope.** Die Prüfung sitzt im Core, nicht im Tool und nicht im Adapter.
- **Destruktives läuft über Pending Actions.** Löschen, MX/NS/SOA ändern, Domain entfernen, Subaccounts: `prepare_*` erzeugt eine Datei in `pending/`, die App gibt frei und führt aus. Die feste Liste steht im Core, Policies können sie erweitern, nicht verkürzen.
- **Alles ins Audit.** Jeder Tool-Aufruf schreibt eine Zeile nach `audit.jsonl`: Client, Verbindung, `resource:action`, Ziel, Ergebnis, Provider-Aufruf ohne Secrets, Dauer.
- **Rate-Limits im Adapter.** All-Inkl `KasFloodDelay` je Antwort, Cloudflare 1200 je 5 Minuten pro User, Hostinger 90 pro Minute, Namecheap 50 pro Minute, 700 pro Stunde, 8000 pro Tag. Aufrufe pro Verbindung seriell.
- **Swift 6, strikte Concurrency, async/await, `@Observable`.** Keine Callbacks, kein Combine im neuen Code.
- **SOAP für KAS von Hand.** Eine Operation `KasApi(Params)` mit JSON-String im Envelope, Antwort per `XMLParser`. Keine SOAP-Bibliothek.

## Namen und Vokabular

- Ressourcen und Aktionen heißen wie im Konzept: `mailbox`, `mail_forward`, `mail_autoresponder`, `dns_record`, `cron_job`, ... Aktionen `list`, `get`, `create`, `update`, `set_password`, `delete`. Audit-Schreibweise `resource:action`.
- Rechtestufen `none`, `read`, `write`, `manage`.
- MCP-Tools: `<resource>_<action>`, übergreifende Tools mit Präfix `kastellan_`.
- Deutsche UI-Strings, englische Code-Identifier. Tool-Beschreibungen deutsch und englisch.

## Build und Tooling

- Projekt wird aus `project.yml` mit XcodeGen generiert. `.xcodeproj` ist in `.gitignore`, nie von Hand editieren.
- Team-ID, Bundle-IDs und Entitlements stehen in `project.yml`. Jedes Target hat eine eigene versionierte Info.plist.
- Build ohne Signatur zum Testen: `xcodebuild -project Kastellan.xcodeproj -scheme Kastellan -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- Core-Tests: `cd Packages/KastellanCore && swift test`
- Release später headless nach der Vault-Notiz `04 Ressourcen/Apple Developer/Mac- und iOS-Apps ohne Xcode bauen und shippen.md` (notarytool, stapler). Das Regelwerk dafür entsteht mit Frank vor dem ersten Release.
- Git-Identität in diesem Repo: `Frank Neumann-Staude <frank@staude.net>`.

## Was nicht

- Keine Scraper für Hoster ohne API (Strato, 1blu, Host Europe, webgo).
- Kein Domain-Kauf, keine Rechnungs- oder Vertragsverwaltung.
- Keine Analytics, kein Tracking.

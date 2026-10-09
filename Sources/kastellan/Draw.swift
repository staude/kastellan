import Foundation
import KastellanCore

extension TUI {
    /// Zeichnet den ganzen Bildschirm neu: Kopfzeile, Bereichsliste links, Inhalt, Fußzeile, Dialog.
    func draw() {
        let (cols, rows) = terminal.size
        let sidebar = 20
        let contentWidth = max(cols - sidebar - 3, 20)
        let bodyRows = max(rows - 3, 5)

        var screen: [String] = []
        let pendingBadge = pending.isEmpty ? "" : "  ● \(pending.count) offene Freigabe\(pending.count == 1 ? "" : "n")"
        screen.append(Line(" KASTELLAN ", Style.header + Style.bold).adding("  Profil \(profile?.name ?? "–")", Style.header)
            .adding(pendingBadge, Style.header + Style.bold).render(width: cols, fill: Style.header))

        let content: [Line] = switch section {
        case .overview: overviewLines(width: contentWidth)
        case .connections: connectionsLines(width: contentWidth)
        case .permissions: permissionsLines(width: contentWidth)
        case .clients: clientsLines(width: contentWidth)
        case .approvals: approvalsLines(width: contentWidth)
        case .audit: auditLines(width: contentWidth, height: bodyRows)
        }
        // Lange Inhalte so verschieben, dass die Auswahl sichtbar bleibt.
        let offset = section == .audit ? 0 : max(0, scrollAnchor(for: content) - bodyRows + 3)

        for row in 0..<bodyRows {
            var left = Line()
            if row == 0 { left = Line() } else if row - 1 < Section.allCases.count {
                let s = Section.allCases[row - 1]
                let badge = s == .approvals && !pending.isEmpty ? " \(pending.count)" : ""
                left = Line(" \(s.rawValue + 1) \(s.title)\(badge)", s == section ? Style.selected : "")
            }
            let right = content.indices.contains(row + offset) ? content[row + offset] : Line()
            screen.append(left.render(width: sidebar, fill: section == Section.allCases[safe: row - 1] ? Style.selected : "")
                          + Style.muted + " │ " + Style.reset + right.render(width: contentWidth))
        }

        screen.append(Line(status ?? "", Style.gold).render(width: cols))
        screen.append(Line(hints, Style.muted).render(width: cols))

        if let modal { overlay(modal, on: &screen, cols: cols, rows: rows) }

        var out = "\u{1B}[H"
        for (i, line) in screen.prefix(rows).enumerated() { out += "\u{1B}[\(i + 1);1H" + line }
        terminal.write(out)
    }

    /// Zeile der aktuellen Auswahl im Inhalt, grob über den markierten Stil gefunden.
    private func scrollAnchor(for content: [Line]) -> Int {
        content.lastIndex { line in line.parts.contains { $0.1 == Style.selected } } ?? 0
    }

    var hints: String {
        if modal != nil { return " Dialog: Enter bestätigen · Esc abbrechen" }
        let global = "1–6 Bereich · Tab weiter · P Profil · r neu laden · q beenden"
        let local: String = switch section {
        case .overview: ""
        case .connections: "↑↓ wählen · n neu · e bearbeiten · h prüfen · x löschen · "
        case .permissions: "↑↓ Ressource · ←→ Stufe · Leertaste Freigabe für Anlegen/Ändern · t Client · c Verbindung · "
        case .clients: "↑↓ wählen · n neuer Client · x widerrufen · "
        case .approvals: "↑↓ wählen · f freigeben · v verwerfen · "
        case .audit: "↑↓ blättern · "
        }
        return " " + local + global
    }

    private func overlay(_ modal: Modal, on screen: inout [String], cols: Int, rows: Int) {
        var title = ""
        var body: [Line] = []
        switch modal {
        case .form(let form):
            title = form.title
            body = form.lines(width: min(cols - 8, 90))
        case .confirm(let text, _):
            title = "Bestätigen"
            body = text.split(separator: "\n").map { Line(String($0)) } + [Line(), Line("j = ja · n = nein", Style.muted)]
        case .message(let t, let lines):
            title = t
            body = lines.map { Line($0) } + [Line(), Line("Beliebige Taste schließt", Style.muted)]
        case .input(let t, let text, _):
            title = t
            body = [Line("› ", Style.gold).adding(text, Style.bold).adding("▏", Style.gold), Line(), Line("Enter übernehmen · Esc abbrechen", Style.muted)]
        case .choice(let t, let options, let index, _):
            title = t
            body = options.enumerated().map { i, o in Line(" \(o) ", i == index ? Style.selected : "") } + [Line(), Line("↑↓ wählen · Enter übernehmen · Esc abbrechen", Style.muted)]
        }
        let width = min(cols - 4, max(50, min(100, (body.map(\.width).max() ?? 40) + 6)))
        let height = body.count + 4
        let top = max(1, (rows - height) / 2)
        let left = max(0, (cols - width) / 2)
        var boxed: [String] = []
        boxed.append(Style.gold + "╭─ " + Style.bold + title + Style.reset + Style.gold + " " + String(repeating: "─", count: max(0, width - title.count - 5)) + "╮" + Style.reset)
        boxed.append(Style.gold + "│" + Style.reset + Line().render(width: width - 2) + Style.gold + "│" + Style.reset)
        for line in body {
            boxed.append(Style.gold + "│ " + Style.reset + line.render(width: width - 4) + Style.gold + " │" + Style.reset)
        }
        boxed.append(Style.gold + "╰" + String(repeating: "─", count: width - 2) + "╯" + Style.reset)
        for (i, text) in boxed.enumerated() {
            let row = top + i
            guard screen.indices.contains(row) else { continue }
            // Ganze Zeile bleibt, der Kasten wird per Spaltenposition darübergeschrieben.
            screen[row] = screen[row] + "\u{1B}[\(row + 1);\(left + 1)H" + text
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

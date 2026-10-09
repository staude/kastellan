import Foundation
import KastellanCore

// Tasten und Inhalte der einzelnen Bereiche.

extension TUI {
    // MARK: Verbindungen

    func connectionsKey(_ key: Key) async {
        let list = profileConnections
        moveSelection(key, count: list.count)
        let current = selected(list.count).map { list[$0] }
        switch key {
        case .char("n"):
            guard let profile else { return }
            modal = .form(ConnectionForm(tui: self, profile: profile, existing: nil))
        case .char("e"), .enter:
            guard let current, let profile else { return }
            modal = .form(ConnectionForm(tui: self, profile: profile, existing: current))
        case .char("h"):
            guard let current else { return }
            checkHealth(current)
        case .char("x"):
            guard let current else { return }
            modal = .confirm("Verbindung „\(current.label)“ löschen? Rechte, Zuordnungen und gespeicherte Zugangsdaten werden entfernt.") { [self] in
                do {
                    try await runtime.connections.delete(id: current.id)
                    try await runtime.policies.removeConnection(current.id)
                    try await runtime.assignments.removeConnection(current.id)
                    if let store = runtime.secrets as? any ManagedSecretStore { try store.deleteAll(connectionID: current.id) }
                    status = "Verbindung gelöscht."
                } catch { modal = .message("Löschen fehlgeschlagen", [error.localizedDescription]) }
                await reload()
            }
        default: break
        }
    }

    func checkHealth(_ connection: Connection) {
        status = "Prüfe \(connection.label) …"
        background("health-\(connection.id)") { [self] in
            do {
                let adapter = try runtime.registry.adapter(for: connection, secrets: runtime.secrets)
                let result = await adapter.healthCheck()
                try runtime.health.append(result)
                status = "\(connection.label): \(result.ok ? "ok" : "Fehler") – \(result.message)"
            } catch {
                try? runtime.health.append(HealthStatus(connectionID: connection.id, ok: false, message: error.localizedDescription))
                status = "\(connection.label): \(error.localizedDescription)"
            }
        }
    }

    func connectionsLines(width: Int) -> [Line] {
        var lines: [Line] = [Line("Verbindungen im Profil \(profile?.name ?? "–")", Style.bold), Line()]
        let list = profileConnections
        if list.isEmpty { lines.append(Line("Noch keine Verbindung. Mit n eine anlegen.", Style.muted)) }
        let sel = selected(list.count)
        for (i, c) in list.enumerated() {
            let provider = runtime.registry.entry(for: c.provider)?.displayName ?? c.provider
            let h = health[c.id]
            let dot = busy.contains("health-\(c.id)") ? ("◌", Style.gold) : h.map { $0.ok ? ("●", Style.green) : ("●", Style.red) } ?? ("○", Style.muted)
            var line = Line(" ")
            line.add(dot.0, i == sel ? Style.selected : dot.1)
            line.add(" \(c.label.padded(28)) \(provider.padded(16)) ", i == sel ? Style.selected : "")
            line.add(h?.message ?? "noch nicht geprüft", i == sel ? Style.selected : Style.muted)
            lines.append(line)
        }
        if let sel, list.indices.contains(sel), let entry = runtime.registry.entry(for: list[sel].provider) {
            lines.append(Line())
            lines.append(Line("Fähigkeiten von \(entry.displayName)", Style.gold))
            for group in ResourceType.Group.allCases {
                let resources = ResourceType.allCases.filter { $0.group == group && entry.capabilityMatrix.resources.contains($0) }
                guard !resources.isEmpty else { continue }
                let text = resources.map { r in
                    let actions = Action.allCases.filter { entry.capabilityMatrix.supports(Capability(r, $0)) }.map(\.rawValue)
                    return "\(r.displayName) (\(actions.joined(separator: ", ")))"
                }.joined(separator: "; ")
                lines.append(Line("  \(group.rawValue): ", Style.muted).adding(text))
            }
            if !list[sel].settings.isEmpty {
                lines.append(Line("  Einstellungen: ", Style.muted).adding(list[sel].settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))
            }
        }
        return lines
    }

    // MARK: Rechte

    var permissionResources: [ResourceType] {
        let conns = profileConnections
        guard conns.indices.contains(permConnection), let matrix = runtime.registry.capabilityMatrix(for: conns[permConnection].provider) else { return [] }
        return ResourceType.allCases.filter { matrix.resources.contains($0) }
    }

    func loadPolicy() async {
        let toks = profileTokens, conns = profileConnections
        guard let profile, toks.indices.contains(permToken), conns.indices.contains(permConnection) else { policy = Policy(); return }
        policy = (try? await runtime.policies.policy(profile: profile.slug, client: toks[permToken].client, connectionID: conns[permConnection].id)) ?? Policy()
    }

    func savePolicy() async {
        let toks = profileTokens, conns = profileConnections
        guard let profile, toks.indices.contains(permToken), conns.indices.contains(permConnection) else { return }
        do {
            try await runtime.policies.set(policy, profile: profile.slug, client: toks[permToken].client, connectionID: conns[permConnection].id)
            status = "Gespeichert für \(toks[permToken].client) auf \(conns[permConnection].label)."
        } catch {
            modal = .message("Speichern fehlgeschlagen", [error.localizedDescription])
        }
    }

    static let writeActions: [Action] = [.create, .update, .setPassword]

    func writeNeedsConfirmation(_ r: ResourceType) -> Bool { policy.confirmExtra.contains("\(r.rawValue):create") }

    func permissionsKey(_ key: Key) async {
        let toks = profileTokens, conns = profileConnections
        let resources = permissionResources
        switch key {
        case .char("t"):
            guard !toks.isEmpty else { return }
            permToken = (permToken + 1) % toks.count
            await loadPolicy()
        case .char("c"):
            guard !conns.isEmpty else { return }
            permConnection = (permConnection + 1) % conns.count
            selection[.permissions] = 0
            await loadPolicy()
        case .left, .right, .char("h"), .char("l"):
            guard let i = selected(resources.count) else { return }
            let r = resources[i]
            let levels = PermissionLevel.allCases
            let current = levels.firstIndex(of: policy.level(for: r)) ?? 0
            let next = (key == .left || key == .char("h")) ? max(0, current - 1) : min(levels.count - 1, current + 1)
            policy.levels[r] = levels[next]
            await savePolicy()
        case .char(" "):
            guard let i = selected(resources.count) else { return }
            let r = resources[i]
            guard policy.level(for: r) >= .write else { status = "Erst Stufe write oder manage setzen."; return }
            var set = Set(policy.confirmExtra)
            let on = !writeNeedsConfirmation(r)
            for a in Self.writeActions {
                let k = "\(r.rawValue):\(a.rawValue)"
                if on { set.insert(k) } else { set.remove(k) }
            }
            policy.confirmExtra = set.sorted()
            await savePolicy()
        default:
            moveSelection(key, count: resources.count)
        }
    }

    func permissionsLines(width: Int) -> [Line] {
        let toks = profileTokens, conns = profileConnections
        guard !toks.isEmpty else { return [Line("Kein Client-Token im Profil. Unter MCP-Clients (4) eines anlegen.", Style.muted)] }
        guard !conns.isEmpty else { return [Line("Keine Verbindung im Profil. Unter Verbindungen (2) eine anlegen.", Style.muted)] }
        permToken = min(permToken, toks.count - 1); permConnection = min(permConnection, conns.count - 1)
        var lines: [Line] = [
            Line("Client-Token  ", Style.muted).adding(toks[permToken].client, Style.gold).adding("   (t wechseln, \(toks.count) im Profil)", Style.muted),
            Line("Verbindung    ", Style.muted).adding(conns[permConnection].label, Style.gold).adding("   (c wechseln, \(conns.count) im Profil)", Style.muted),
            Line(),
        ]
        let resources = permissionResources
        let sel = selected(resources.count)
        for (i, r) in resources.enumerated() {
            let isSel = i == sel
            var line = Line(" \(r.displayName.padded(24))", isSel ? Style.selected : "")
            for level in PermissionLevel.allCases {
                let on = policy.level(for: r) == level
                line.add(" ")
                line.add(on ? "[\(level.rawValue)]" : " \(level.rawValue) ", on ? Style.gold + Style.bold : Style.muted)
            }
            if policy.level(for: r) >= .write {
                line.add(writeNeedsConfirmation(r) ? "   ☑ Anlegen/Ändern mit Freigabe" : "   ☐ Anlegen/Ändern mit Freigabe", Style.muted)
            }
            lines.append(line)
        }
        if let sel, resources.indices.contains(sel) {
            lines.append(Line())
            lines.append(Line(resources[sel].explanation, Style.muted))
        }
        lines.append(Line())
        lines.append(Line("none: unsichtbar · read: lesen · write: anlegen, ändern · manage: auch löschen und MX/NS/SOA. Löschen läuft immer über eine Freigabe.", Style.dim))
        return lines
    }

    // MARK: MCP-Clients

    func clientsKey(_ key: Key) async {
        let toks = profileTokens
        moveSelection(key, count: toks.count)
        switch key {
        case .char("n"):
            guard let profile else { return }
            modal = .input("Name des Clients (etwa Claude Code)", "", { [self] name in
                let name = name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let targets = MCPConfigWriter.Target.allCases
                modal = .choice("Wohin soll der Eintrag?", targets.map { "\($0.displayName) (\($0.defaultFile.path))" } + ["Nur Token anzeigen"], 0, { [self] choice in
                    do {
                        let issued = try await runtime.tokens.issue(client: name, profileID: profile.id)
                        let writer = MCPConfigWriter(executable: MCPConfigWriter.bundledExecutable())
                        if targets.indices.contains(choice) {
                            let file = try writer.install(token: issued.token, target: targets[choice], profile: profile)
                            modal = .message("Client \(name) eingerichtet", [
                                "Eintrag \(MCPConfigWriter.serverName(profile: profile)) in \(file.path) geschrieben.",
                                "Programm: \(writer.executable.path)",
                                "\(targets[choice].displayName) neu starten oder MCP-Server neu laden.",
                            ])
                        } else {
                            modal = .message("Token für \(name)", [
                                "Wird nur jetzt angezeigt:", "", issued.token, "",
                                "Als KASTELLAN_TOKEN für \(writer.executable.path) setzen.",
                            ])
                        }
                    } catch { modal = .message("Fehler", [error.localizedDescription]) }
                    await reload()
                })
            })
        case .char("x"):
            guard let i = selected(toks.count) else { return }
            let t = toks[i]
            modal = .confirm("Token „\(t.client)“ widerrufen? Der Client verliert sofort den Zugriff.") { [self] in
                do { try await runtime.tokens.revoke(id: t.id); status = "Token widerrufen." } catch { modal = .message("Fehler", [error.localizedDescription]) }
                await reload()
            }
        default: break
        }
    }

    func clientsLines(width: Int) -> [Line] {
        var lines: [Line] = [Line("Client-Tokens im Profil \(profile?.name ?? "–")", Style.bold), Line()]
        let toks = profileTokens
        if toks.isEmpty { lines.append(Line("Noch kein Client. Mit n einen anlegen und die Konfiguration schreiben lassen.", Style.muted)) }
        let sel = selected(toks.count)
        for (i, t) in toks.enumerated() {
            let s = i == sel ? Style.selected : ""
            lines.append(Line(" \(t.client.padded(26)) angelegt \(t.createdAt.short)   zuletzt \(t.lastUsedAt?.short ?? "nie")", s))
        }
        lines.append(Line())
        lines.append(Line("MCP-Programm: \(MCPConfigWriter.bundledExecutable().path)", Style.muted))
        if let profile {
            for target in MCPConfigWriter.Target.allCases {
                let installed = MCPConfigWriter(executable: MCPConfigWriter.bundledExecutable()).isInstalled(target: target, profile: profile)
                lines.append(Line("\(target.displayName): ", Style.muted).adding(installed ? "Eintrag \(MCPConfigWriter.serverName(profile: profile)) vorhanden" : "kein Eintrag", installed ? Style.green : Style.muted))
            }
        }
        return lines
    }

    // MARK: Freigaben

    func approvalsKey(_ key: Key) async {
        moveSelection(key, count: pending.count)
        guard let i = selected(pending.count) else { return }
        let action = pending[i]
        guard action.status == .prepared, !busy.contains(action.id) else { return }
        switch key {
        case .char("f"), .enter:
            modal = .confirm("Freigeben und ausführen?\n\(action.preview)") { [self] in
                background(action.id) { [self] in
                    do {
                        let done = try await service.approve(pendingID: action.id, by: user)
                        status = done.status == .done ? "Ausgeführt: \(action.preview)" : "Status \(done.status.rawValue): \(done.error ?? "")"
                    } catch { modal = .message("Freigabe fehlgeschlagen", [error.localizedDescription]) }
                }
            }
        case .char("v"):
            modal = .confirm("Verwerfen?\n\(action.preview)") { [self] in
                do { _ = try await service.reject(pendingID: action.id, by: user); status = "Verworfen." } catch { modal = .message("Fehler", [error.localizedDescription]) }
                await reload(light: true)
            }
        default: break
        }
    }

    func approvalsLines(width: Int) -> [Line] {
        var lines: [Line] = [Line("Offene Freigaben", Style.bold), Line()]
        if pending.isEmpty { lines.append(Line("Nichts offen.", Style.muted)) }
        let sel = selected(pending.count)
        for (i, a) in pending.enumerated() {
            let s = i == sel ? Style.selected : ""
            let state = busy.contains(a.id) || a.status == .executing ? "läuft …" : a.status == .prepared ? "wartet" : a.status.rawValue
            lines.append(Line(" \(a.preview)", s.isEmpty ? Style.gold : s))
            lines.append(Line("   \(a.client) · \(label(of: a.connectionID)) · \(a.createdAt.short) · \(state)", Style.muted))
        }
        lines.append(Line())
        lines.append(Line("Zuletzt entschieden", Style.bold))
        for a in finished {
            let color = a.status == .done ? Style.green : a.status == .failed ? Style.red : Style.muted
            lines.append(Line(" \(a.status.rawValue.padded(10))", color).adding(" \(a.preview)").adding("  \(a.client), \((a.finishedAt ?? a.createdAt).short)", Style.muted))
        }
        return lines
    }

    // MARK: Protokoll

    func auditLines(width: Int, height: Int) -> [Line] {
        var lines: [Line] = [Line("Protokoll (neueste zuerst, \(audit.count) Einträge)", Style.bold), Line()]
        let sel = selected(audit.count) ?? 0
        let visible = max(height - 3, 1)
        let start = max(0, min(sel - visible / 2, audit.count - visible))
        for (i, e) in audit.enumerated().dropFirst(start).prefix(visible) {
            let color: String = switch e.outcome {
            case .ok, .confirmed: Style.green
            case .denied, .error: Style.red
            case .pending: Style.gold
            default: Style.muted
            }
            let s = i == sel ? Style.selected : ""
            var line = Line(" \(e.timestamp.short) ", s.isEmpty ? Style.muted : s)
            line.add(e.outcome.rawValue.padded(12), s.isEmpty ? color : s)
            line.add("\(e.client.padded(16)) \((e.capability?.description ?? e.tool ?? "").padded(24)) \(e.target ?? "") \(e.message.map { "– \($0)" } ?? "")", s)
            lines.append(line)
        }
        return lines
    }

    // MARK: Übersicht

    func overviewLines(width: Int) -> [Line] {
        let conns = profileConnections
        let failing = conns.filter { health[$0.id]?.ok == false }
        var lines: [Line] = [
            Line("Kastellan \(KastellanCore.version)", Style.gold + Style.bold).adding("  Verwaltung für Hoster, mit MCP-Server für Claude", Style.muted),
            Line(),
            Line("Profil         ", Style.muted).adding(profile?.name ?? "–").adding(profiles.count > 1 ? "   (P wechseln: \(profiles.map(\.name).joined(separator: ", ")))" : "", Style.muted),
            Line("Verbindungen   ", Style.muted).adding("\(conns.count)").adding(failing.isEmpty ? "" : ", \(failing.count) mit Fehler", Style.red),
            Line("Client-Tokens  ", Style.muted).adding("\(profileTokens.count)"),
            Line("Freigaben      ", Style.muted).adding("\(pending.count) offen", pending.isEmpty ? "" : Style.gold),
            Line(),
            Line("Daten          ", Style.muted).adding(AppPaths.home.path),
            Line("Zugangsdaten   ", Style.muted).adding((runtime.secrets as? any ManagedSecretStore)?.displayName ?? "–"),
            Line("MCP-Programm   ", Style.muted).adding(MCPConfigWriter.bundledExecutable().path),
            Line("System         ", Style.muted).adding(PlatformInfo.name),
            Line(),
        ]
        if !pending.isEmpty {
            lines.append(Line("Offene Freigaben", Style.bold))
            for a in pending.prefix(5) { lines.append(Line(" • \(a.preview)", Style.gold)) }
            lines.append(Line(" Unter 5 freigeben oder verwerfen.", Style.muted))
            lines.append(Line())
        }
        if !failing.isEmpty {
            lines.append(Line("Verbindungen mit Fehler", Style.bold))
            for c in failing { lines.append(Line(" • \(c.label): ", Style.red).adding(health[c.id]?.message ?? "")) }
        }
        return lines
    }
}

extension String {
    func padded(_ width: Int) -> String {
        count >= width ? String(prefix(max(width - 1, 0))) + (width > 0 ? " " : "") : self + String(repeating: " ", count: width - count)
    }
}

extension Date {
    var short: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = Calendar.current.isDateInToday(self) ? "HH:mm" : "dd.MM. HH:mm"
        return f.string(from: self)
    }
}

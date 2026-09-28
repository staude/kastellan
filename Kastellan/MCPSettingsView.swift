import SwiftUI
import KastellanCore
import AppKit

/// Bereich „MCP": Client-Tokens ausstellen, widerrufen und den Eintrag in die
/// Claude-Konfiguration schreiben. Entspricht der MCP-Seite von TorroMail.
struct MCPSettingsView: View {
    let model: AppModel
    @State private var newClientName = "Claude Code"
    @State private var issued: IssuedToken?
    @State private var message: String?
    @State private var errorText: String?

    private var writer: MCPConfigWriter { MCPConfigWriter(executable: MCPConfigWriter.bundledExecutable()) }

    private var profile: KastellanProfile? { model.selectedProfile }

    var body: some View {
        Form {
            Section("MCP-Server für Profil \(profile?.name ?? "–")") {
                LabeledContent("Binary", value: MCPConfigWriter.bundledExecutable().path)
                    .textSelection(.enabled)
                if let profile {
                    LabeledContent("Servername", value: MCPConfigWriter.serverName(profile: profile))
                    ForEach(MCPConfigWriter.Target.allCases, id: \.self) { target in
                        LabeledContent(target.displayName) {
                            HStack {
                                Text(writer.isInstalled(target: target, profile: profile) ? "eingetragen" : "nicht eingetragen")
                                    .foregroundStyle(.secondary)
                                Button("Eintragen") { install(target, profile) }
                                if writer.isInstalled(target: target, profile: profile) {
                                    Button("Entfernen") { uninstall(target, profile) }
                                }
                            }
                        }
                    }
                }
                Text("„Eintragen“ stellt ein neues Token für den Client in diesem Profil aus und schreibt den Eintrag in die Konfigurationsdatei. Vorher wird eine Sicherungskopie angelegt. Claude danach neu starten.")
                    .kFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Token für eigenen Client") {
                HStack {
                    TextField("Client-Name", text: $newClientName)
                    Button("Token erstellen") { issue() }
                        .disabled(newClientName.trimmingCharacters(in: .whitespaces).isEmpty || profile == nil)
                }
                if let issued {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Token für \(issued.record.client) im Profil \(model.profileName(issued.record.profileID)). Wird nur jetzt angezeigt.")
                            .kFont(.caption)
                        Text(issued.token)
                            .kFont(.body, design: .monospaced)
                            .textSelection(.enabled)
                        HStack {
                            Button("Token kopieren") { copy(issued.token) }
                            if let profile {
                                Button("Snippet für Claude Code kopieren") {
                                    copy(writer.snippet(token: issued.token, target: .claudeCode, profile: profile))
                                }
                            }
                        }
                    }
                }
            }

            Section("Ausgestellte Tokens") {
                if model.tokens.isEmpty {
                    Text("Noch keine Tokens.").foregroundStyle(.secondary)
                }
                ForEach(model.tokens.filter { $0.profileID == profile?.id }) { token in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(token.client)
                            Text("angelegt \(token.createdAt.formatted(date: .abbreviated, time: .shortened))"
                                 + (token.lastUsedAt.map { ", zuletzt \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                                .kFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if token.isRevoked {
                            Text("widerrufen").foregroundStyle(.secondary)
                        } else {
                            Button("Widerrufen") { revoke(token) }
                        }
                    }
                }
            }

            if let message {
                Text(message).foregroundStyle(.green)
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task {
            await model.reloadProfiles()
            await model.reloadTokens()
        }
    }

    private func issue() {
        guard let profile else { return }
        Task {
            do {
                issued = try await model.tokenStore.issue(client: newClientName.trimmingCharacters(in: .whitespaces), profileID: profile.id)
                errorText = nil
                await model.reloadTokens()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func install(_ target: MCPConfigWriter.Target, _ profile: KastellanProfile) {
        Task {
            do {
                let t = try await model.tokenStore.issue(client: target.displayName, profileID: profile.id)
                let file = try writer.install(token: t.token, target: target, profile: profile)
                message = "Eintrag in \(file.path) geschrieben."
                errorText = nil
                await model.reloadTokens()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func uninstall(_ target: MCPConfigWriter.Target, _ profile: KastellanProfile) {
        do {
            try writer.uninstall(target: target, profile: profile)
            message = "Eintrag aus \(target.displayName) entfernt. Das Token bleibt bestehen, bei Bedarf widerrufen."
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revoke(_ token: ClientToken) {
        Task {
            do {
                try await model.tokenStore.revoke(id: token.id)
                await model.reloadTokens()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

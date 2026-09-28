import SwiftUI
import KastellanCore

/// Einstellungen der Passwort-Ablage je Profil: nur im Ergebnis, Schlüsselbund, Bitwarden, 1Password.
struct CredentialSettingsView: View {
    let model: AppModel
    @State private var config = CredentialDeliveryConfig()
    @State private var masterPassword = ""
    @State private var bwStatus: BitwardenStatus?
    @State private var opStatus: OnePasswordStatus?
    @State private var folders: [BitwardenFolder] = []
    @State private var organizations: [BitwardenOrganization] = []
    @State private var collections: [BitwardenCollection] = []
    @State private var vaults: [OnePasswordVault] = []
    @State private var busy = false
    @State private var message: String?
    @State private var errorText: String?

    private var profile: KastellanProfile? { model.selectedProfile }

    var body: some View {
        Card(title: "Passwort-Ablage für Profil \(profile?.name ?? "–")") {
            CardRow {
                Text("Erzeugte Passwörter gehen an"); Spacer()
                Picker("Ablage", selection: $config.kind) {
                    ForEach(CredentialSinkKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 220)
                .onChange(of: config.kind) { Task { await refreshStatus() } }
            }
            switch config.kind {
            case .resultOnly:
                CardRow(last: true) {
                    Text("Das Passwort erscheint nur im Ergebnis des Aufrufs und wird nirgends gespeichert. Der Assistent gibt es weiter, etwa in eine .env-Datei.")
                        .kFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .keychain:
                CardRow(last: true) {
                    Text("Als Internet-Passwort im Login-Schlüsselbund: Benutzername, Server, Protokoll, Kastellan-Notiz. Sichtbar in der Schlüsselbundverwaltung, nicht in Apples Passwörter-App.")
                        .kFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .bitwarden:
                bitwardenRows
            case .onepassword:
                onePasswordRows
            }
            CardRow(last: true) {
                if let message { Text(message).kFont(.caption).foregroundStyle(Theme.ok) }
                if let errorText { Text(errorText).kFont(.caption).foregroundStyle(Theme.bad) }
                Spacer()
                Button("Übernehmen") { save() }.buttonStyle(.borderedProminent).tint(Theme.gold).disabled(profile == nil)
            }
        }
        .task { await load() }
        .onChange(of: model.selectedProfile?.id) { Task { await load() } }
    }

    // MARK: Bitwarden

    @ViewBuilder private var bitwardenRows: some View {
        CardRow {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bitwarden-CLI").kFont(.body)
                Text(bitwardenStatusText).kFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Status prüfen") { Task { await refreshStatus() } }
        }
        if let bw = bwStatus, bw.installed, bw.state == "unauthenticated" {
            CardRow {
                Text("Die CLI ist abgemeldet. Im Terminal „bw login“ ausführen (E-Mail, Master-Passwort, ggf. Zwei-Faktor), danach hier Status prüfen und entsperren.")
                    .kFont(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
        } else if let bw = bwStatus, bw.installed {
            CardRow {
                if model.bitwardenSession == nil {
                    SecureField("Master-Passwort", text: $masterPassword).frame(width: 220)
                    Button("Entsperren") { Task { await unlock() } }.disabled(masterPassword.isEmpty || busy)
                    Text("Der Schlüssel bleibt nur im Speicher der App, bis Sie sperren oder die App beenden.").kFont(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Entsperrt").foregroundStyle(Theme.ok)
                    Button("Sperren") { Task { await model.lockBitwarden(); await refreshStatus() } }
                    Button("Listen laden") { Task { await loadBitwardenLists() } }.disabled(busy)
                }
                Spacer()
            }
            CardRow {
                Text("Organisation"); Spacer()
                Picker("Organisation", selection: Binding(get: { config.target.organizationID ?? "" }, set: { id in
                    config.target.organizationID = id.isEmpty ? nil : id
                    config.target.organizationName = organizations.first { $0.id == id }?.name
                    config.target.collectionIDs = []; config.target.collectionNames = []
                    Task { await loadCollections() }
                })) {
                    Text("Persönlicher Tresor").tag("")
                    ForEach(organizations) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(width: 260)
            }
            if config.target.organizationID != nil {
                CardRow {
                    Text("Sammlung"); Spacer()
                    Picker("Sammlung", selection: Binding(get: { config.target.collectionIDs.first ?? "" }, set: { id in
                        config.target.collectionIDs = id.isEmpty ? [] : [id]
                        config.target.collectionNames = collections.filter { $0.id == id }.map(\.name)
                    })) {
                        Text("keine").tag("")
                        ForEach(collections) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(width: 260)
                }
            } else {
                CardRow {
                    Text("Ordner"); Spacer()
                    Picker("Ordner", selection: Binding(get: { config.target.folderID ?? "" }, set: { id in
                        config.target.folderID = id.isEmpty ? nil : id
                        config.target.folderName = folders.first { $0.id == id }?.name
                    })) {
                        Text("Kein Ordner").tag("")
                        ForEach(folders.filter { $0.id != nil }, id: \.id) { Text($0.name).tag($0.id ?? "") }
                    }.labelsHidden().frame(width: 260)
                }
            }
            if !model.handoffs.isEmpty {
                CardRow {
                    Text("\(model.handoffs.count) Zugänge warten auf Ablage").foregroundStyle(Theme.warn)
                    Spacer()
                    Button("Jetzt ablegen") { Task { await model.processHandoffs(retryFailed: true); message = "Übergaben verarbeitet." } }.disabled(model.bitwardenSession == nil)
                }
            }
        } else {
            CardRow {
                Text("Installation: brew install bitwarden-cli, dann bw login. Danach hier Status prüfen.").kFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var bitwardenStatusText: String {
        guard let bw = bwStatus else { return "noch nicht geprüft" }
        guard bw.installed else { return "nicht installiert" }
        let state = ["locked": "gesperrt", "unlocked": "entsperrt", "unauthenticated": "abgemeldet"][bw.state] ?? bw.state
        return "Version \(bw.version ?? "?"), \(bw.userEmail ?? "nicht angemeldet"), Server \(bw.serverURL ?? "bitwarden.com"), Zustand \(state)"
        #if false
        return "Version \(bw.version ?? "?"), \(bw.userEmail ?? "nicht angemeldet"), Server \(bw.serverURL ?? "bitwarden.com"), Zustand \(bw.state)"
        #endif
    }

    // MARK: 1Password

    @ViewBuilder private var onePasswordRows: some View {
        CardRow {
            VStack(alignment: .leading, spacing: 2) {
                Text("1Password-CLI").kFont(.body)
                Text(opStatus.map { $0.installed ? "Version \($0.version ?? "?"), \($0.signedIn ? "angemeldet als \($0.account ?? "?")" : "nicht angemeldet, App-Integration prüfen")" : "nicht installiert (brew install 1password-cli)" } ?? "noch nicht geprüft")
                    .kFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Status prüfen") { Task { await refreshStatus() } }
            Button("Tresore laden") { Task { await loadVaults() } }.disabled(opStatus?.signedIn != true)
        }
        CardRow {
            Text("Tresor"); Spacer()
            Picker("Tresor", selection: Binding(get: { config.target.vault ?? "" }, set: { config.target.vault = $0.isEmpty ? nil : $0 })) {
                Text("Standard (Private)").tag("")
                ForEach(vaults) { Text($0.name).tag($0.name) }
            }.labelsHidden().frame(width: 260)
        }
        if !model.handoffs.isEmpty {
            CardRow {
                Text("\(model.handoffs.count) Zugänge warten auf Ablage").foregroundStyle(Theme.warn)
                Spacer()
                Button("Jetzt ablegen") { Task { await model.processHandoffs(retryFailed: true); message = "Übergaben verarbeitet." } }
            }
        }
    }

    // MARK: Aktionen

    private func load() async {
        guard let profile else { return }
        config = (try? await model.runtime.credentialSettings.config(profileID: profile.id)) ?? CredentialDeliveryConfig()
        await refreshStatus()
    }

    private func refreshStatus() async {
        switch config.kind {
        case .bitwarden:
            bwStatus = await model.bitwardenSink.status()
            if model.bitwardenSession != nil { await loadBitwardenLists() }
        case .onepassword:
            opStatus = await model.onePasswordSink.status()
        default: break
        }
    }

    private func unlock() async {
        busy = true; defer { busy = false }
        do {
            try await model.unlockBitwarden(masterPassword: masterPassword)
            masterPassword = ""
            errorText = nil
            message = "Bitwarden entsperrt."
            await refreshStatus()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadBitwardenLists() async {
        busy = true; defer { busy = false }
        do {
            folders = try await model.bitwardenSink.folders()
            organizations = try await model.bitwardenSink.organizations()
            await loadCollections()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadCollections() async {
        guard let org = config.target.organizationID else { collections = []; return }
        collections = (try? await model.bitwardenSink.collections(organizationID: org)) ?? []
    }

    private func loadVaults() async {
        do { vaults = try await model.onePasswordSink.vaults(); errorText = nil } catch { errorText = error.localizedDescription }
    }

    private func save() {
        guard let profile else { return }
        Task {
            do {
                try await model.runtime.credentialSettings.set(config, profileID: profile.id)
                message = "Ablage für \(profile.name): \(config.kind.displayName)\(config.target.description.isEmpty ? "" : ", \(config.target.description)")"
                errorText = nil
            } catch { errorText = error.localizedDescription }
        }
    }
}

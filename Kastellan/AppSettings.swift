import Foundation
import SwiftUI
import ServiceManagement
import AppKit
import KastellanCore

/// Einstellungen der App, gespeichert in `<Home>/settings.json`. Telemetrie-Schalter schreibt `telemetry.json`,
/// das der Core in beiden Prozessen liest.
@Observable
@MainActor
final class AppSettings {
    var showInMenuBar: Bool { didSet { save(); apply() } }
    var keepInDock: Bool { didSet { save(); apply() } }
    /// Schriftgröße als Stufe in `textSizes`; Standard ist eine Stufe über der Systemgröße.
    /// Nie im didSet zuweisen: unter @Observable löst das den Setter erneut aus (Endlosrekursion).
    var textSizeStep: Int { didSet { save() } }

    nonisolated static let textSizes: [CGFloat] = [0.85, 0.92, 1.0, 1.1, 1.2, 1.3, 1.45, 1.6]
    nonisolated static let defaultTextSizeStep = 4

    var textScale: CGFloat { Self.textSizes[Self.clamp(textSizeStep)] }
    nonisolated static func clamp(_ step: Int) -> Int { min(max(step, 0), textSizes.count - 1) }
    var canIncreaseText: Bool { textSizeStep < Self.textSizes.count - 1 }
    var canDecreaseText: Bool { textSizeStep > 0 }

    func increaseText() { if canIncreaseText { textSizeStep += 1 } }
    func decreaseText() { if canDecreaseText { textSizeStep -= 1 } }
    func resetText() { textSizeStep = Self.defaultTextSizeStep }
    var telemetryEnabled: Bool { didSet { saveTelemetry() } }
    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    var launchAtLoginError: String?
    /// Vom Fenster gesetzt, damit die App ohne Dock und Menüleiste sichtbar bleibt, solange es offen ist.
    var windowVisible = false { didSet { apply() } }

    private struct Stored: Codable {
        var showInMenuBar = true
        var keepInDock = true
        var textSizeStep = AppSettings.defaultTextSizeStep
        enum CodingKeys: String, CodingKey {
            case showInMenuBar = "show_in_menu_bar"
            case keepInDock = "keep_in_dock"
            case textSizeStep = "text_size_step"
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
            keepInDock = try c.decodeIfPresent(Bool.self, forKey: .keepInDock) ?? true
            textSizeStep = try c.decodeIfPresent(Int.self, forKey: .textSizeStep) ?? AppSettings.defaultTextSizeStep
        }
    }

    private static var file: URL { AppPaths.home.appendingPathComponent("settings.json") }
    private static var telemetryFile: URL { AppPaths.home.appendingPathComponent("telemetry.json") }
    private var loading = true

    init() {
        let stored = (try? JSONCoding.decoder.decode(Stored.self, from: Data(contentsOf: Self.file))) ?? Stored()
        showInMenuBar = stored.showInMenuBar
        keepInDock = stored.keepInDock
        textSizeStep = Self.clamp(stored.textSizeStep)
        telemetryEnabled = Self.readTelemetry()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loading = false
        // Kein apply() hier: NSApp existiert während App.init noch nicht. Das Fenster setzt windowVisible.
    }

    private func save() {
        guard !loading else { return }
        var stored = Stored()
        stored.showInMenuBar = showInMenuBar
        stored.keepInDock = keepInDock
        stored.textSizeStep = textSizeStep
        if let data = try? JSONCoding.encoder.encode(stored) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    /// Dock-Symbol nur, wenn gewünscht oder das Fenster offen ist.
    private func apply() {
        guard !loading else { return }
        let app = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = (keepInDock || windowVisible) ? .regular : .accessory
        if app.activationPolicy() != policy {
            app.setActivationPolicy(policy)
        }
    }

    private func applyLaunchAtLogin() {
        guard !loading else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            loading = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loading = false
        }
    }

    private static func readTelemetry() -> Bool {
        guard let data = try? Data(contentsOf: telemetryFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = obj["enabled"] as? Bool else { return false }
        return enabled
    }

    private func saveTelemetry() {
        guard !loading else { return }
        let obj: [String: Any] = ["enabled": telemetryEnabled]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: Self.telemetryFile, options: .atomic)
        }
    }
}

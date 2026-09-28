import Foundation
import Sparkle

/// Besitzt Sparkle für die Laufzeit der App und bietet nur die zwei Entscheidungen an, die die
/// Oberfläche braucht: automatisch prüfen ja oder nein, und jetzt prüfen. Vorbild ist TorroMail.
///
/// Sparkle prüft beim Start und danach alle 24 Stunden (`SUScheduledCheckInterval` in der
/// Info.plist) gegen `releases/latest/download/appcast.xml` auf GitHub, lädt ein neues DMG im
/// Hintergrund und installiert es beim nächsten Beenden. Debug-Builds und Bundles ohne Feed oder
/// Schlüssel bleiben stumm: ein Entwickler-Build soll sich nie selbst durch ein Release ersetzen,
/// weil dessen Signatur eine andere ist und der Schlüsselbund die Zugangsdaten dann nicht mehr freigibt.
@Observable
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController?

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    init(bundle: Bundle = .main) {
        if Self.canStart(in: bundle) {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
        automaticallyChecksForUpdates = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    var isAvailable: Bool { controller != nil }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private static func canStart(in bundle: Bundle) -> Bool {
        #if DEBUG
        return false
        #else
        guard bundle.bundleIdentifier != nil,
              bundle.bundlePath.hasSuffix(".app"),
              bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              bundle.object(forInfoDictionaryKey: "KastellanDisableUpdates") as? Bool != true,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty, !key.hasPrefix("__") else { return false }
        return true
        #endif
    }
}

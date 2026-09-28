import SwiftUI

/// Appweite Schriftskalierung. macOS kennt kein Dynamic Type, deshalb eigener Faktor im Environment.
struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension Font.TextStyle {
    /// Basisgrößen von macOS in Punkt.
    var baseSize: CGFloat {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }
}

struct ScaledFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        var font = Font.system(size: style.baseSize * scale, weight: weight ?? (style == .headline ? .semibold : .regular), design: design)
        if monospacedDigit { font = font.monospacedDigit() }
        return content.font(font)
    }
}

extension View {
    /// Skalierte Schrift; ersetzt `.font(.caption)` und Verwandte in der App.
    func kFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default, monospacedDigit: Bool = false) -> some View {
        modifier(ScaledFont(style: style, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }
}

/// Farben und Bausteine nach TorroMail-Vorbild: dunkle Fläche, Karten, farbiges Kopfbanner.
enum Theme {
    static let background = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let sidebar = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let card = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let cardStroke = Color.white.opacity(0.07)
    static let gold = Color(red: 0.851, green: 0.663, blue: 0.235)
    static let goldDark = Color(red: 0.66, green: 0.47, blue: 0.11)
    static let navy = Color(red: 0.086, green: 0.125, blue: 0.169)
    static let slate = Color(red: 0.184, green: 0.243, blue: 0.306)
    static let ok = Color(red: 0.30, green: 0.80, blue: 0.40)
    static let warn = Color(red: 0.95, green: 0.65, blue: 0.20)
    static let bad = Color(red: 0.93, green: 0.35, blue: 0.30)
}

/// Karte mit Titel darüber, Inhalt darin.
struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title).kFont(.subheadline, weight: .semibold).foregroundStyle(.secondary) }
                    Spacer()
                    if let trailing { trailing }
                }
                .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardStroke))
        }
    }
}

/// Eine Zeile in einer Karte, mit Trennlinie darunter.
struct CardRow<Content: View>: View {
    var last = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            if !last { Divider().overlay(Theme.cardStroke).padding(.leading, 14) }
        }
    }
}

/// Farbiger Punkt für Status.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.6), radius: 3)
    }
}

/// Symbolkachel wie die roten Mail-Kacheln bei TorroMail.
struct SymbolTile: View {
    let symbol: String
    var color: Color = Theme.gold
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.navy)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Kopfbanner mit Wortmarke und Claim.
struct HeaderBanner: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Theme.slate, Theme.navy], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 170, weight: .bold))
                .foregroundStyle(Theme.gold.opacity(0.18))
                .rotationEffect(.degrees(-30))
                .offset(x: 40, y: 10)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Wordmark(size: 26)
                Text("Hoster-Zugänge für KI-Assistenten. Nichts Destruktives ohne Freigabe.")
                    .kFont(.callout)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(height: 150)
        .clipped()
    }
}

/// Wortmarke KASTELLAN mit Schlüssel.
struct Wordmark: View {
    var size: CGFloat = 18
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: size * 0.8, weight: .bold))
                .foregroundStyle(Theme.gold)
            Text("KASTELLAN")
                .font(.system(size: size, weight: .black, design: .rounded))
                .kerning(1.5)
                .foregroundStyle(.white)
        }
    }
}

extension AuditEntryPresentation {
    static func label(tool: String?, capability: String?) -> String {
        guard let tool else { return capability ?? "" }
        switch tool {
        case "kastellan_version": return "Version abgefragt"
        case "kastellan_list_connections": return "Verbindungen aufgelistet"
        case "kastellan_get_capabilities": return "Berechtigungen abgefragt"
        case "kastellan_get_policy": return "Policy gelesen"
        case "kastellan_resolve": return "Zuständigkeit ermittelt"
        case "kastellan_list_pending", "kastellan_get_pending": return "Freigaben abgefragt"
        case "kastellan_confirm_action": return "Freigabe erteilt"
        case "kastellan_cancel_action": return "Freigabe verworfen"
        default:
            return ActionDescriptions.german[tool] ?? tool
        }
    }
}

enum AuditEntryPresentation {}

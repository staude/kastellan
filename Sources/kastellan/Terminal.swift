import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// Tastendruck nach dem Zerlegen der Eingabebytes.
enum Key: Equatable {
    case char(Character)
    case up, down, left, right, home, end, pageUp, pageDown
    case enter, tab, backTab, backspace, delete, escape
    case ctrl(Character)
}

/// Rohes Terminal: alternative Bildschirmseite, keine Echo- und Zeilenpufferung, VT-Sequenzen.
/// Funktioniert auf macOS und Linux (termios) und unter Windows (Konsolenmodus mit VT-Ein- und -Ausgabe,
/// Windows Terminal oder Konsole ab Windows 10).
final class Terminal: @unchecked Sendable {
    #if os(Windows)
    private var originalIn: DWORD = 0
    private var originalOut: DWORD = 0
    #else
    private var original = termios()
    #endif
    private var active = false

    func start() {
        #if os(Windows)
        let input = GetStdHandle(STD_INPUT_HANDLE), output = GetStdHandle(STD_OUTPUT_HANDLE)
        GetConsoleMode(input, &originalIn)
        GetConsoleMode(output, &originalOut)
        let inMode = (originalIn & ~DWORD(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)) | DWORD(ENABLE_VIRTUAL_TERMINAL_INPUT)
        SetConsoleMode(input, inMode)
        SetConsoleMode(output, originalOut | DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING) | DWORD(DISABLE_NEWLINE_AUTO_RETURN))
        SetConsoleOutputCP(UINT(CP_UTF8))
        SetConsoleCP(UINT(CP_UTF8))
        #else
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        #endif
        active = true
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[2J")
    }

    func stop() {
        guard active else { return }
        active = false
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        #if os(Windows)
        SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), originalIn)
        SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), originalOut)
        #else
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        #endif
    }

    func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// Spalten und Zeilen; Standard 100 × 30, wenn die Größe nicht ermittelbar ist.
    var size: (cols: Int, rows: Int) {
        #if os(Windows)
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info) {
            return (Int(info.srWindow.Right - info.srWindow.Left + 1), Int(info.srWindow.Bottom - info.srWindow.Top + 1))
        }
        return (100, 30)
        #else
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 { return (Int(ws.ws_col), Int(ws.ws_row)) }
        return (100, 30)
        #endif
    }

    /// Liest Bytes von stdin in einem eigenen Thread und liefert Tasten. Eine Escape-Sequenz kommt in
    /// der Regel in einem Lesevorgang an; ein einzelnes ESC gilt als Escape-Taste.
    func keys(_ handler: @escaping @Sendable (Key) -> Void) {
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 64)
            while true {
                let n = Self.readStdin(&buffer)
                if n <= 0 { continue }
                for key in Self.parse(Array(buffer[0..<n])) { handler(key) }
            }
        }
    }

    private static func readStdin(_ buffer: inout [UInt8]) -> Int {
        #if os(Windows)
        var read: DWORD = 0
        let ok = buffer.withUnsafeMutableBytes { ReadFile(GetStdHandle(STD_INPUT_HANDLE), $0.baseAddress, DWORD($0.count), &read, nil) }
        return ok ? Int(read) : -1
        #else
        return buffer.withUnsafeMutableBytes { Foundation.read(STDIN_FILENO, $0.baseAddress, $0.count) }
        #endif
    }

    static func parse(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B {
                if i + 1 >= bytes.count { keys.append(.escape); i += 1; continue }
                if bytes[i + 1] == 0x5B || bytes[i + 1] == 0x4F { // CSI oder SS3
                    var j = i + 2
                    var params = ""
                    while j < bytes.count, (0x30...0x3F).contains(bytes[j]) { params.append(Character(UnicodeScalar(bytes[j]))); j += 1 }
                    guard j < bytes.count else { keys.append(.escape); i = j; continue }
                    let final = bytes[j]
                    switch final {
                    case 0x41: keys.append(.up)
                    case 0x42: keys.append(.down)
                    case 0x43: keys.append(.right)
                    case 0x44: keys.append(.left)
                    case 0x48: keys.append(.home)
                    case 0x46: keys.append(.end)
                    case 0x5A: keys.append(.backTab)
                    case 0x7E:
                        switch params {
                        case "1", "7": keys.append(.home)
                        case "4", "8": keys.append(.end)
                        case "3": keys.append(.delete)
                        case "5": keys.append(.pageUp)
                        case "6": keys.append(.pageDown)
                        default: break
                        }
                    default: break
                    }
                    i = j + 1
                    continue
                }
                keys.append(.escape); i += 1; continue
            }
            switch b {
            case 0x0D, 0x0A: keys.append(.enter)
            case 0x09: keys.append(.tab)
            case 0x7F, 0x08: keys.append(.backspace)
            case 0x01...0x1A: keys.append(.ctrl(Character(UnicodeScalar(b + 0x60))))
            default:
                // UTF-8-Zeichen zusammensetzen
                let length = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
                let end = min(i + length, bytes.count)
                if let s = String(bytes: bytes[i..<end], encoding: .utf8), let c = s.first { keys.append(.char(c)) }
                i = end
                continue
            }
            i += 1
        }
        return keys
    }
}

// MARK: - Darstellung

/// Farben und Stile als ANSI-Sequenzen, angelehnt an die App (Gold auf Nachtblau).
enum Style {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let gold = "\u{1B}[38;2;212;166;70m"
    static let red = "\u{1B}[38;2;232;98;92m"
    static let green = "\u{1B}[38;2;110;196;120m"
    static let muted = "\u{1B}[38;2;150;158;175m"
    static let selected = "\u{1B}[48;2;212;166;70m\u{1B}[38;2;20;28;48m"
    static let header = "\u{1B}[48;2;20;28;48m\u{1B}[38;2;212;166;70m"
}

/// Eine Bildschirmzeile aus Teilen mit Stil. Sichtbare Breite zählt Zeichen ohne Sequenzen.
struct Line {
    var parts: [(String, String)] = []

    init(_ text: String = "", _ style: String = "") { if !text.isEmpty { parts.append((Self.clean(text), style)) } }

    mutating func add(_ text: String, _ style: String = "") { parts.append((Self.clean(text), style)) }

    /// Steuerzeichen (C0, DEL, C1) aus angezeigtem Text entfernen. Vorschauen, Protokoll und Health-Meldungen
    /// stammen teils von MCP-Clients oder Providern; eingeschleuste Escape-Sequenzen könnten sonst den
    /// Bildschirm umschreiben, etwa den Text einer Freigabe. Stile kommen nur aus den `Style`-Konstanten.
    static func clean(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { s in
            s.value < 0x20 || (0x7F...0x9F).contains(s.value) ? (s == "\t" ? " " : "\u{FFFD}") : s
        }))
    }

    func adding(_ text: String, _ style: String = "") -> Line { var l = self; l.add(text, style); return l }

    var width: Int { parts.reduce(0) { $0 + $1.0.count } }

    /// Auf genau `width` Zeichen kürzen oder auffüllen; `fill` gibt der Auffüllung einen Stil.
    func render(width: Int, fill: String = "") -> String {
        var out = ""
        var used = 0
        for (text, style) in parts {
            guard used < width else { break }
            let room = width - used
            let piece = text.count > room ? String(text.prefix(max(room - 1, 0))) + "…" : text
            out += style + piece + Style.reset
            used += piece.count
        }
        if used < width { out += fill + String(repeating: " ", count: width - used) + Style.reset }
        return out
    }
}

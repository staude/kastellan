import Foundation

/// Ermittelt die öffentliche IPv4 dieses Macs über Cloudflares Trace-Endpunkt. Das Ziel ist die
/// IPv4-Adresse 1.1.1.1, die Antwort enthält deshalb immer die IPv4, auch wenn der Mac sonst IPv6
/// bevorzugt. Nur auf ausdrücklichen Wunsch aufrufen (Knopf im Editor, Diagnose bei IP-Fehlern).
public enum PublicIPv4 {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let traceURL = URL(string: "https://1.1.1.1/cdn-cgi/trace")!

    public static func detect(fetch: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await URLSession.shared.data(for: request).0
    }) async throws -> String {
        let text = String(decoding: try await fetch(traceURL), as: UTF8.self)
        guard let ip = parse(text) else {
            throw KastellanError.provider("Öffentliche IPv4 nicht ermittelbar: Antwort von 1.1.1.1 ohne gültige Adresse")
        }
        return ip
    }

    /// Liest `ip=…` aus der Trace-Antwort und akzeptiert nur IPv4.
    static func parse(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("ip=") {
            let ip = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts.allSatisfy({ p in p.count <= 3 && Int(p).map { (0...255).contains($0) } == true }) else { return nil }
            return ip
        }
        return nil
    }
}

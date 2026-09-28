import Foundation

/// HTTP-Schicht des Cloudflare-Clients. Tests ersetzen sie durch einen Stub mit Fixture-Antworten,
/// damit nie ein echter Aufruf gegen api.cloudflare.com läuft.
public protocol CloudflareTransport: Sendable {
    /// Sendet einen Request gegen die REST-API v4 und liefert Body und HTTP-Antwort. Fehlerstatus
    /// (4xx, 5xx) kommen als Antwort zurück, nicht als Fehler: der Body enthält den Cloudflare-Envelope.
    func request(method: String, path: String, query: [String: String], body: Data?, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}

/// Standard-Transport über `URLSession`.
public struct URLSessionCloudflareTransport: CloudflareTransport {
    public static let baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    private let session: URLSession
    private let baseURL: URL
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, baseURL: URL = URLSessionCloudflareTransport.baseURL, timeout: TimeInterval = 60) {
        self.session = session
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public func request(method: String, path: String, query: [String: String], body: Data?, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let url = Self.url(base: baseURL, path: path, query: query)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Kastellan/\(KastellanCore.version)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KastellanError.provider("Cloudflare: keine HTTP-Antwort")
        }
        return (data, http)
    }

    /// `path` beginnt mit `/`, Query-Parameter werden sortiert angehängt (stabil für Logs und Tests).
    static func url(base: URL, path: String, query: [String: String]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        return components.url!
    }
}

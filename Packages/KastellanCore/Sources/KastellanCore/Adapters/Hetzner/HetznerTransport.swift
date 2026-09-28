import Foundation

/// Rohe HTTP-Antwort der Hetzner Cloud API. Statuscode und Header bleiben erhalten,
/// weil der Client daraus Rate-Limit und Fehlerbehandlung ableitet.
public struct HetznerResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Header-Zugriff ohne Rücksicht auf Groß- und Kleinschreibung.
    public func header(_ name: String) -> String? {
        if let v = headers[name] { return v }
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// HTTP-Schicht des Hetzner-Clients. Tests ersetzen sie durch einen Stub mit Fixture-Antworten.
/// Der Client baut den vollständigen `URLRequest` (URL, Methode, Body, Authorization).
public protocol HetznerTransport: Sendable {
    /// Sendet den Request und liefert die Antwort. Fehlerstatus (4xx, 5xx) kommen als Antwort
    /// zurück, nicht als Fehler; nur Netzwerkfehler werfen.
    func send(_ request: URLRequest) async throws -> HetznerResponse
}

/// Standard-Transport über `URLSession`.
public struct URLSessionHetznerTransport: HetznerTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HetznerResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KastellanError.provider("Hetzner: keine HTTP-Antwort")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return HetznerResponse(status: http.statusCode, headers: headers, body: data)
    }
}

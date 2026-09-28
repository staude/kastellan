import Foundation

/// HTTP-Schicht des KAS-Clients. Tests ersetzen sie durch einen Stub mit Fixture-Antworten.
public protocol KASTransport: Sendable {
    /// Sendet einen SOAP-Request und liefert den rohen Antwort-Body. SOAP-Faults kommen mit
    /// HTTP 500 und werden als Body zurückgegeben, nicht als Fehler.
    func post(url: URL, soapAction: String, body: Data) async throws -> Data
}

/// Standard-Transport über `URLSession`.
public struct URLSessionKASTransport: KASTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 60) {
        self.session = session
        self.timeout = timeout
    }

    public func post(url: URL, soapAction: String, body: Data) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(soapAction)\"", forHTTPHeaderField: "SOAPAction")
        request.setValue("Kastellan/\(KastellanCore.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KastellanError.provider("KAS: keine HTTP-Antwort")
        }
        // 500 ist bei SOAP der reguläre Statuscode für Faults, der Body enthält die Fehlerbeschreibung.
        guard http.statusCode == 200 || (http.statusCode == 500 && !data.isEmpty) else {
            throw KastellanError.provider("KAS: HTTP \(http.statusCode)")
        }
        return data
    }
}

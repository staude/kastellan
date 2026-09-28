import Foundation

/// Rohe HTTP-Antwort der hosting.de-API. Fehlerstatus kommen als Antwort zurück, nicht als Fehler.
public struct HostingDeResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

/// HTTP-Schicht des hosting.de-Clients. Tests ersetzen sie durch einen Stub mit Fixture-Antworten.
public protocol HostingDeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HostingDeResponse
}

/// Standard-Transport über `URLSession`.
public struct URLSessionHostingDeTransport: HostingDeTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HostingDeResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KastellanError.provider("hosting.de: keine HTTP-Antwort")
        }
        return HostingDeResponse(status: http.statusCode, body: data)
    }
}

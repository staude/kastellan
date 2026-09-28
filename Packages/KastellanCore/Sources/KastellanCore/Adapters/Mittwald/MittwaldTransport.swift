import Foundation

/// Rohe HTTP-Antwort der mStudio-API. Header bleiben erhalten (Pagination, Rate-Limit, etag).
public struct MittwaldResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public func header(_ name: String) -> String? {
        if let v = headers[name] { return v }
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// HTTP-Schicht des Mittwald-Clients; Tests ersetzen sie durch einen Stub.
public protocol MittwaldTransport: Sendable {
    func send(_ request: URLRequest) async throws -> MittwaldResponse
}

/// Standard-Transport über `URLSession`; 307/308-Redirects folgt URLSession mit Methode und Body.
public struct URLSessionMittwaldTransport: MittwaldTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> MittwaldResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KastellanError.provider("Mittwald: keine HTTP-Antwort")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return MittwaldResponse(status: http.statusCode, headers: headers, body: data)
    }
}

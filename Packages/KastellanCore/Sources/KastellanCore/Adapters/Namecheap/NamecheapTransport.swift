import Foundation

/// Rohe HTTP-Antwort der Namecheap-API. Fehler kommen auch bei HTTP 200 im XML (`Status="ERROR"`).
public struct NamecheapResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status; self.body = body
    }
}

public protocol NamecheapTransport: Sendable {
    func send(_ request: URLRequest) async throws -> NamecheapResponse
}

public struct URLSessionNamecheapTransport: NamecheapTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> NamecheapResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KastellanError.provider("Namecheap: keine HTTP-Antwort")
        }
        return NamecheapResponse(status: http.statusCode, body: data)
    }
}

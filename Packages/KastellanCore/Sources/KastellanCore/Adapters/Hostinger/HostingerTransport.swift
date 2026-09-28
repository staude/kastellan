import Foundation

/// Rohe HTTP-Antwort der Hostinger-API. Header bleiben für Rate-Limit und Pagination erhalten.
public struct HostingerResponse: Sendable {
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

public protocol HostingerTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HostingerResponse
}

public struct URLSessionHostingerTransport: HostingerTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> HostingerResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KastellanError.provider("Hostinger: keine HTTP-Antwort")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return HostingerResponse(status: http.statusCode, headers: headers, body: data)
    }
}

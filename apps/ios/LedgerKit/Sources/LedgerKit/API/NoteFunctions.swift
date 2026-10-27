import Foundation

/// Calls the notes' price refresh (`stock-prices`, JSON) with the user's JWT. The request is built
/// purely so its bytes are testable; errors are read like `statements-upload`'s.
public struct NoteFunctions: Sendable {
    let functionsURL: URL
    let apiKey: String
    let session: URLSession

    public init(functionsURL: URL, apiKey: String, session: URLSession = .shared) {
        self.functionsURL = functionsURL
        self.apiKey = apiKey
        self.session = session
    }

    public func pricesRequest(profileCode: String, accessToken: String) -> URLRequest {
        var request = request("stock-prices", accessToken: accessToken, timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["profile_code": profileCode], options: [.sortedKeys])
        return request
    }

    public func refreshPrices(profileCode: String, accessToken: String) async throws -> NotePriceRefresh {
        let data = try await send(pricesRequest(profileCode: profileCode, accessToken: accessToken))
        return try LedgerJSON.decode(NotePriceRefresh.self, from: data)
    }

    private func request(_ name: String, accessToken: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: functionsURL.appendingPathComponent(name))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw LedgerAPIError.network(error.code.rawValue.description)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw StatementUploader.error(status: status, data: data) }
        return data
    }
}

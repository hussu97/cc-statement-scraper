import Foundation

/// Calls the notes' Edge Functions with the user's JWT: `termsheet-extract` (multipart, one PDF)
/// and `stock-prices` (JSON). Requests are built purely so their bytes are testable; errors are
/// read like `statements-upload`'s.
public struct NoteFunctions: Sendable {
    public static let maxBytes = 25 * 1024 * 1024

    let functionsURL: URL
    let apiKey: String
    let session: URLSession

    public init(functionsURL: URL, apiKey: String, session: URLSession = .shared) {
        self.functionsURL = functionsURL
        self.apiKey = apiKey
        self.session = session
    }

    public func extractRequest(file: UploadFile, profileCode: String, accessToken: String) -> URLRequest {
        var form = MultipartForm()
        form.addField("profile_code", profileCode)
        form.addFile("file", filename: file.filename, mimeType: "application/pdf", data: file.data)
        // The model reads the PDF for up to 140 s.
        var request = request("termsheet-extract", accessToken: accessToken, timeout: 180)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        return request
    }

    public func pricesRequest(profileCode: String, accessToken: String) -> URLRequest {
        var request = request("stock-prices", accessToken: accessToken, timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["profile_code": profileCode], options: [.sortedKeys])
        return request
    }

    public func extract(file: UploadFile, profileCode: String, accessToken: String) async throws -> TermSheetExtract {
        if file.data.count > Self.maxBytes {
            throw LedgerAPIError.server(status: 413, code: "FILE_TOO_LARGE", message: "\(file.filename) is larger than 25 MB.")
        }
        let data = try await send(extractRequest(file: file, profileCode: profileCode, accessToken: accessToken))
        return try TermSheetExtract.decode(data)
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

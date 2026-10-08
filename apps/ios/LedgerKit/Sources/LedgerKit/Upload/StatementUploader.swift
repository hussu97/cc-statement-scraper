import Foundation

/// `multipart/form-data` body builder. Pure, so the exact bytes are testable.
public struct MultipartForm: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "ledger-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.quote(name))\"\r\n\r\n")
        append("\(value)\r\n")
    }

    public mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.quote(name))\"; filename=\"\(Self.quote(filename))\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    public func finalized() -> Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    private mutating func append(_ s: String) { body.append(Data(s.utf8)) }

    /// Quotes and line breaks would end the header early.
    static func quote(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// Posts PDFs to the `statements-upload` Edge Function with the user's JWT.
/// Used by the app's document picker and by the Share Extension.
public struct StatementUploader: Sendable {
    public static let maxFiles = 20
    public static let maxBytes = 25 * 1024 * 1024

    let functionsURL: URL
    let apiKey: String
    let session: URLSession

    public init(functionsURL: URL, apiKey: String, session: URLSession = .shared) {
        self.functionsURL = functionsURL
        self.apiKey = apiKey
        self.session = session
    }

    public func makeRequest(files: [UploadFile], profileCode: String, accessToken: String) -> URLRequest {
        var form = MultipartForm()
        form.addField("profile_code", profileCode)
        form.addField("source", "ios")
        for file in files {
            form.addFile("files", filename: file.filename, mimeType: "application/pdf", data: file.data)
        }
        var request = URLRequest(url: functionsURL.appendingPathComponent("statements-upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.httpBody = form.finalized()
        return request
    }

    public func upload(files: [UploadFile], profileCode: String, accessToken: String) async throws -> UploadResponse {
        guard !files.isEmpty else { return UploadResponse(uploads: []) }
        if files.count > Self.maxFiles {
            throw LedgerAPIError.server(status: 413, code: "TOO_MANY_FILES", message: "Upload at most \(Self.maxFiles) PDFs at a time.")
        }
        if let big = files.first(where: { $0.data.count > Self.maxBytes }) {
            throw LedgerAPIError.server(status: 413, code: "FILE_TOO_LARGE", message: "\(big.filename) is larger than 25 MB.")
        }
        let request = makeRequest(files: files, profileCode: profileCode, accessToken: accessToken)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw LedgerAPIError.network(error.code.rawValue.description)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Self.error(status: status, data: data)
        }
        return try LedgerJSON.decode(UploadResponse.self, from: data)
    }

    /// Edge Functions answer `{"error": {"code", "message"}}` or `{"code", "message"}`.
    static func error(status: Int, data: Data) -> LedgerAPIError {
        struct Body: Decodable {
            struct Inner: Decodable { let code: String?; let message: String? }
            let error: Inner?
            let code: String?
            let message: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let code = body?.error?.code ?? body?.code
        let message = body?.error?.message ?? body?.message ?? "Upload failed (\(status))."
        if status == 401 { return .notSignedIn }
        return .server(status: status, code: code, message: message)
    }
}

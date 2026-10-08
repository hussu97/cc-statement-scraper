import Foundation
import Testing
@testable import LedgerKit

/// Answers every request from a canned response and records the request.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@Suite("statements-upload client", .serialized)
struct StatementUploaderTests {
    let uploader = StatementUploader(functionsURL: URL(string: "http://127.0.0.1:54321/functions/v1")!,
                                     anonKey: "anon-key", session: StubURLProtocol.session())
    let pdf = UploadFile(filename: "FAB \"Sept\".pdf", data: Data("%PDF-1.7\n...".utf8))

    @Test("multipart request: user JWT, apikey, profile_code, source=ios, files[]")
    func request() throws {
        let req = uploader.makeRequest(files: [pdf], profileCode: "prf_01hzy3k8w9m2n4p6q8r0s2t4v6", accessToken: "jwt")
        #expect(req.url?.absoluteString == "http://127.0.0.1:54321/functions/v1/statements-upload")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
        #expect(req.value(forHTTPHeaderField: "apikey") == "anon-key")
        let contentType = try #require(req.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary=ledger-"))
        let body = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"profile_code\"\r\n\r\nprf_01hzy3k8w9m2n4p6q8r0s2t4v6\r\n"))
        #expect(body.contains("name=\"source\"\r\n\r\nios\r\n"))
        #expect(body.contains("name=\"files\"; filename=\"FAB 'Sept'.pdf\"\r\nContent-Type: application/pdf\r\n\r\n%PDF-1.7"))
        #expect(body.hasSuffix("--\r\n"))
    }

    @Test("200 decodes the uploads summary")
    func success() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.body = Data(#"{"uploads":[{"filename":"a.pdf","doc_code":"doc_1","status":"queued"},{"filename":"b.pdf","doc_code":"doc_2","status":"duplicate"}]}"#.utf8)
        let response = try await uploader.upload(files: [pdf], profileCode: "prf_x", accessToken: "jwt")
        #expect(response.uploads.map(\.docCode) == ["doc_1", "doc_2"])
        #expect(response.summary == "1 queued, 1 already uploaded")
    }

    @Test("Edge Function errors surface their message; 401 means signed out")
    func errors() async throws {
        StubURLProtocol.statusCode = 403
        StubURLProtocol.body = Data(#"{"error":{"code":"FORBIDDEN","message":"not an owner of this profile"}}"#.utf8)
        await #expect(throws: LedgerAPIError.server(status: 403, code: "FORBIDDEN", message: "not an owner of this profile")) {
            try await uploader.upload(files: [pdf], profileCode: "prf_x", accessToken: "jwt")
        }
        StubURLProtocol.statusCode = 401
        StubURLProtocol.body = Data()
        await #expect(throws: LedgerAPIError.notSignedIn) {
            try await uploader.upload(files: [pdf], profileCode: "prf_x", accessToken: "jwt")
        }
    }

    @Test("files over 25 MB are refused before any request")
    func tooLarge() async {
        let big = UploadFile(filename: "big.pdf", data: Data(count: StatementUploader.maxBytes + 1))
        await #expect(throws: LedgerAPIError.self) {
            try await uploader.upload(files: [big], profileCode: "prf_x", accessToken: "jwt")
        }
    }
}

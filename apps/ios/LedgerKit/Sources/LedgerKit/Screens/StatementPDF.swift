import Foundation
import Observation

/// Opens a statement's PDF on the phone (PAR-13): a signed URL as the web gets it, then the
/// bytes, kept in memory only while the viewer is open (never written to disk or a cache).
@MainActor
@Observable
public final class StatementPDF {
    /// The `statements` storage bucket (migration `20261008000300_documents_statements`).
    public nonisolated static let bucket = "statements"
    /// The web's signed-URL lifetime: long enough to fetch the file, short enough not to linger.
    public nonisolated static let signedURLSeconds = 120

    /// A downloaded PDF for the viewer sheet.
    public struct Document: Identifiable, Sendable {
        public let id = UUID()
        public let data: Data
        public let title: String
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The statement has no document, or the document no storage path.
        case notAvailable
        /// Storage refused (the server's message).
        case storage(String)
        /// What came back isn't a PDF (an HTML error page, an empty body).
        case notPDF

        public var description: String {
            switch self {
            case .notAvailable: "The PDF for this statement isn't available."
            case .storage(let message): StatementPDF.storageMessage(message)
            case .notPDF: "Couldn't open the PDF."
            }
        }
    }

    /// Fetches the signed URL's bytes (URLSession in the app, a stub in tests).
    public typealias Fetch = @Sendable (URL) async throws -> Data

    /// The open viewer's PDF.
    public var document: Document?
    public private(set) var isLoading = false
    public var errorMessage: String?

    private let api: any LedgerAPI
    private let fetch: Fetch

    public init(api: any LedgerAPI, fetch: @escaping Fetch = StatementPDF.download) {
        self.api = api
        self.fetch = fetch
    }

    /// Only a statement with a document has a PDF to open (the web disables its button otherwise).
    public nonisolated static func canOpen(docCode: String?) -> Bool { docCode?.isEmpty == false }

    /// Signs, downloads and presents the PDF; a failure sets `errorMessage`.
    public func open(profileCode: String, docCode: String?, title: String) async {
        guard !isLoading else { return }
        guard let docCode, Self.canOpen(docCode: docCode) else {
            errorMessage = Failure.notAvailable.description
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try await api.statementPDFURL(profileCode: profileCode, docCode: docCode)
            let data = try await fetch(url)
            guard Self.isPDF(data) else { throw Failure.notPDF }
            document = Document(data: data, title: title)
        } catch {
            errorMessage = (error as? Failure)?.description ?? LoadState<Int>.message(for: error)
        }
    }

    /// Drops the bytes when the viewer closes.
    public func close() { document = nil }

    // MARK: Pure

    /// The web's wording: a missing object reads "isn't in storage", anything else as the server said it.
    public nonisolated static func storageMessage(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("not found") || lower.contains("notfound") || lower.contains("not_found") {
            return "The PDF file isn't in storage."
        }
        return message.isEmpty ? "Couldn't open the PDF." : message
    }

    /// A PDF starts with `%PDF-`.
    public nonisolated static func isPDF(_ data: Data) -> Bool {
        data.starts(with: Array("%PDF-".utf8))
    }

    /// Ephemeral: a statement PDF never lands in a URL cache on disk.
    nonisolated static let session = URLSession(configuration: .ephemeral)

    /// The signed URL's bytes; a non-2xx answer is storage's refusal.
    @concurrent
    public nonisolated static func download(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw LedgerAPIError.network(error.code.rawValue.description)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 404 || http.statusCode == 400
                ? Failure.storage("Object not found")
                : LedgerAPIError.server(status: http.statusCode, code: nil, message: "Server error \(http.statusCode)")
        }
        return data
    }
}

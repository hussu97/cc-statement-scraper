import Foundation
import Observation

/// Opens a structured note's term sheet on the phone, the way `StatementPDF` opens a statement:
/// a signed URL from the private `term-sheets` bucket, then the bytes, kept in memory only while
/// the viewer is open. The viewer shares them as a PDF named after the original file.
@MainActor
@Observable
public final class TermSheetPDF {
    /// The `term-sheets` storage bucket (migration `20261027124257_structured_notes`).
    public nonisolated static let bucket = "term-sheets"
    public nonisolated static let notAvailable = "The term sheet for this note isn't available."

    /// A downloaded term sheet for the viewer sheet.
    public struct Document: Identifiable, Sendable {
        public let id = UUID()
        public let data: Data
        public let title: String
        /// What a shared copy is called: the original file name, ending in `.pdf`.
        public let filename: String
    }

    /// The open viewer's term sheet.
    public var document: Document?
    public private(set) var isLoading = false
    public var errorMessage: String?

    private let api: any LedgerAPI
    private let fetch: StatementPDF.Fetch

    public init(api: any LedgerAPI, fetch: @escaping StatementPDF.Fetch = StatementPDF.download) {
        self.api = api
        self.fetch = fetch
    }

    /// Only a note whose term sheet was stored has one to open.
    public nonisolated static func canOpen(path: String?) -> Bool { path?.isEmpty == false }

    /// Signs, downloads and presents the term sheet; a failure sets `errorMessage`.
    public func open(path: String?, filename: String?, title: String) async {
        guard !isLoading else { return }
        guard let path, Self.canOpen(path: path) else {
            errorMessage = Self.notAvailable
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try await api.termSheetPDFURL(path: path)
            let data = try await fetch(url)
            guard StatementPDF.isPDF(data) else { throw StatementPDF.Failure.notPDF }
            document = Document(data: data, title: title, filename: Self.shareFilename(filename, fallback: title))
        } catch {
            errorMessage = (error as? StatementPDF.Failure)?.description ?? LoadState<Int>.message(for: error)
        }
    }

    /// Drops the bytes when the viewer closes.
    public func close() { document = nil }

    // MARK: Pure

    /// A safe file name for the share sheet: the stored name (else the fallback) without path
    /// separators, ending in `.pdf` whatever its case was.
    public nonisolated static func shareFilename(_ filename: String?, fallback: String) -> String {
        let raw = (filename?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        name = name.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "Term sheet" : name) + ".pdf"
    }
}

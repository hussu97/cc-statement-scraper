import Foundation
import Observation

/// Opens a holding's attachment on the phone, the way `TermSheetPDF` opens a term sheet: a signed
/// URL from the private `holding-attachments` bucket, then the bytes, kept in memory only while the
/// viewer is open (never written to disk or a cache). A PDF shows in PDFKit, a photo full screen;
/// both share under the recorded file name.
@MainActor
@Observable
public final class HoldingAttachmentViewer {
    /// A downloaded attachment for the viewer sheet.
    public struct Document: Identifiable, Sendable {
        public let id = UUID()
        public let data: Data
        public let title: String
        /// What a shared copy is called: the recorded name, ending in its type's extension.
        public let filename: String
        public let isPDF: Bool
    }

    /// The open viewer's file.
    public var document: Document?
    /// The attachment being signed and downloaded: its row shows a spinner.
    public private(set) var openingCode: String?
    public var errorMessage: String?

    public var isLoading: Bool { openingCode != nil }

    private let api: any LedgerAPI
    private let fetch: StatementPDF.Fetch

    public init(api: any LedgerAPI, fetch: @escaping StatementPDF.Fetch = StatementPDF.download) {
        self.api = api
        self.fetch = fetch
    }

    /// Signs, downloads and presents the file; a failure sets `errorMessage`. One at a time.
    public func open(_ attachment: HoldingAttachment) async {
        guard openingCode == nil else { return }
        openingCode = attachment.attachmentCode
        defer { openingCode = nil }
        do {
            let url = try await api.holdingAttachmentURL(path: attachment.storagePath)
            let data = try await fetch(url)
            let readable = attachment.isPDF ? StatementPDF.isPDF(data) : HoldingAttachments.isImageData(data)
            guard readable else { throw HoldingAttachments.Failure.unreadable }
            document = Document(data: data, title: attachment.label, filename: HoldingAttachments.shareFilename(attachment),
                                isPDF: attachment.isPDF)
        } catch {
            errorMessage = HoldingAttachments.openMessage(for: error)
        }
    }

    /// Drops the bytes when the viewer closes.
    public func close() { document = nil }
}

import CoreTransferable
import LedgerKit
import SwiftUI
import UniformTypeIdentifiers

/// A structured note's term sheet, shown from memory with PDFKit, with a share button that hands
/// the PDF (under its original file name) to the share sheet: Mail, Messages, Files, Print.
/// `TermSheetPDF` signs and downloads it; the bytes go when the sheet closes.
struct TermSheetSheet: View {
    let document: TermSheetPDF.Document
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFKitView(data: document.data)
                .ignoresSafeArea(edges: .bottom)
                .background(Palette.bg)
                .navigationTitle(document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: SharedPDF(data: document.data, filename: document.filename),
                                  preview: SharePreview(document.filename, image: Image(systemName: "doc.richtext"))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share term sheet")
                    }
                }
        }
    }
}

/// The term sheet row under "Terms": its file name, tappable, a spinner while it downloads.
struct TermSheetRow: View {
    let note: NoteDetail
    let isLoading: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Term sheet").font(Typography.caption).foregroundStyle(Palette.muted)
            if note.hasTermSheet {
                Button(action: open) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.richtext")
                        Text(note.termSheetLabel).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                    .font(Typography.rowMeta)
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: Metrics.tapMin, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityLabel("Open term sheet \(note.termSheetLabel)")
            } else {
                Text("—").font(Typography.rowMeta).foregroundStyle(Palette.ink2)
            }
        }
    }
}

/// PDF bytes for `ShareLink`, exported as a `.pdf` file named after the original.
private struct SharedPDF: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.data }
            .suggestedFileName { $0.filename }
    }
}

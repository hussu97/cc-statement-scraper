import LedgerKit
import PDFKit
import SwiftUI

/// A statement's PDF (PAR-13), shown from memory with PDFKit. `StatementPDF` signs and
/// downloads it; the bytes go when the sheet closes.
struct StatementPDFSheet: View {
    let document: StatementPDF.Document
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFKitView(data: document.data)
                .ignoresSafeArea(edges: .bottom)
                .background(Palette.bg)
                .navigationTitle(document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The toolbar's "View PDF": disabled without a document, a spinner while it downloads.
struct StatementPDFButton: View {
    let pdf: StatementPDF
    let docCode: String?
    let open: () -> Void

    var body: some View {
        if pdf.isLoading {
            ProgressView().accessibilityLabel("Opening the PDF")
        } else {
            Button(action: open) { Image(systemName: "doc.richtext") }
                .disabled(!StatementPDF.canOpen(docCode: docCode))
                .accessibilityLabel("View PDF")
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

import Foundation
import Testing
@testable import LedgerKit

/// A structured note's term sheet opens in the app (signed URL from `term-sheets`, as on the web)
/// and is shared under its original file name.
@MainActor
@Suite("Term sheet PDF: sign, download, show, share")
struct TermSheetPDFTests {
    let path = "prf_a/3f2a.pdf"
    let signed = URL(string: "http://127.0.0.1:54321/storage/v1/object/sign/term-sheets/prf_a/3f2a.pdf?token=t")!
    let pdfBytes = Data("%PDF-1.7\n1 0 obj\n".utf8)

    func note(path: String?, filename: String?) throws -> NoteDetail {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("structured_note_detail")) as? [String: Any])
        var terms = try #require(json["terms"] as? [String: Any])
        terms["termsheet_path"] = path ?? NSNull()
        terms["termsheet_filename"] = filename ?? NSNull()
        json["terms"] = terms
        return try LedgerJSON.decode(NoteDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("the note's stored term sheet is signed and shown, titled by the note, shared by its file name")
    func opens() async throws {
        let api = StubAPI()
        api.noteDetailFixture = try note(path: path, filename: "FinalTS-XS0000000405.PDF")
        api.termSheetURLs[path] = .success(signed)
        let model = NoteDetailModel(holdingCode: "hld_01hzy3k8w9m2n4p6q8r0s2t4v6", api: api, fetchPDF: { _ in pdfBytes })
        await model.load(profileCode: "prf_a")
        #expect(model.state.value?.hasTermSheet == true)
        #expect(model.state.value?.termSheetLabel == "FinalTS-XS0000000405.PDF")
        await model.openTermSheet()
        #expect(api.termSheetURLRequests == [path])
        let doc = try #require(model.termSheet.document)
        #expect(doc.data == pdfBytes && doc.title == model.state.value?.summary.name)
        #expect(doc.filename == "FinalTS-XS0000000405.pdf")
        #expect(model.termSheet.errorMessage == nil && !model.termSheet.isLoading)
        model.termSheet.close()
        #expect(model.termSheet.document == nil)
    }

    @Test("no stored term sheet: no link, nothing signed, a plain message")
    func noTermSheet() async throws {
        let n = try note(path: nil, filename: nil)
        #expect(!n.hasTermSheet && n.termSheetLabel == "Term sheet")
        #expect(!n.termRows.contains { $0.label == "Term sheet" })
        let api = StubAPI()
        let pdf = TermSheetPDF(api: api, fetch: { _ in Data() })
        await pdf.open(path: "", filename: nil, title: "x")
        #expect(api.termSheetURLRequests.isEmpty)
        #expect(pdf.errorMessage == "The term sheet for this note isn't available.")
    }

    @Test("a missing file reads 'isn't in storage'; a non-PDF body is refused")
    func failures() async {
        let api = StubAPI()
        let missing = TermSheetPDF(api: api, fetch: { _ in Data() })
        await missing.open(path: path, filename: nil, title: "x")
        #expect(missing.errorMessage == "The PDF file isn't in storage." && missing.document == nil)

        api.termSheetURLs[path] = .success(signed)
        let html = TermSheetPDF(api: api, fetch: { _ in Data("<html>".utf8) })
        await html.open(path: path, filename: nil, title: "x")
        #expect(html.errorMessage == "Couldn't open the PDF." && html.document == nil)
    }

    @Test("the shared file name: the original, without separators, always ending .pdf")
    func shareFilename() {
        #expect(TermSheetPDF.shareFilename("Final TS GOOGL AMZN META 27% P.A.pdf", fallback: "x") == "Final TS GOOGL AMZN META 27% P.A.pdf")
        #expect(TermSheetPDF.shareFilename("Step-Up Note.PDF", fallback: "x") == "Step-Up Note.pdf")
        #expect(TermSheetPDF.shareFilename("a/b:c", fallback: "x") == "a-b-c.pdf")
        #expect(TermSheetPDF.shareFilename(nil, fallback: "Example Bank B Athena 2029") == "Example Bank B Athena 2029.pdf")
        #expect(TermSheetPDF.shareFilename("  ", fallback: "Example Bank B") == "Example Bank B.pdf")
        #expect(TermSheetPDF.shareFilename(".pdf", fallback: "x") == "Term sheet.pdf")
    }
}

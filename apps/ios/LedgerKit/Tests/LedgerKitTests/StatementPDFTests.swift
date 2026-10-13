import Foundation
import Testing
@testable import LedgerKit

/// PAR-13: a statement's PDF opens on the phone through a signed URL, as on the web.
@MainActor
@Suite("Statement PDF: sign, download, show")
struct StatementPDFTests {
    let docCode = "doc_01hzy3k8w9m2n4p6q8r0s2t4v6"
    let signed = URL(string: "http://127.0.0.1:54321/storage/v1/object/sign/statements/prf_a/x.pdf?token=t")!
    let pdfBytes = Data("%PDF-1.7\n1 0 obj\n".utf8)

    func detailModel(_ api: StubAPI, bytes: Data) async throws -> StatementDetailModel {
        api.detail = try LedgerJSON.decode(StatementDetail.self, from: try fixture("statement_detail"))
        let model = StatementDetailModel(api: api, stmtCode: "stm_01hzy3k8w9m2n4p6q8r0s2t4v6",
                                         fetchPDF: { _ in bytes })
        await model.load(profileCode: "prf_a")
        return model
    }

    @Test("the statement's document is signed and its bytes shown, titled by the statement")
    func opens() async throws {
        let api = StubAPI()
        api.pdfURLs[docCode] = .success(signed)
        let model = try await detailModel(api, bytes: pdfBytes)
        await model.openPDF(profileCode: "prf_a")
        #expect(api.pdfURLRequests.map(\.doc) == [docCode] && api.pdfURLRequests.map(\.profile) == ["prf_a"])
        #expect(model.pdf.document?.data == pdfBytes)
        #expect(model.pdf.document?.title == "Statement 25 Sep 2026")
        #expect(model.pdf.errorMessage == nil && !model.pdf.isLoading)
        model.pdf.close()
        #expect(model.pdf.document == nil)
    }

    @Test("no document: nothing to sign, the web's words")
    func noDocument() async {
        let api = StubAPI()
        let pdf = StatementPDF(api: api, fetch: { _ in Data() })
        #expect(!StatementPDF.canOpen(docCode: nil) && !StatementPDF.canOpen(docCode: ""))
        #expect(StatementPDF.canOpen(docCode: docCode))
        await pdf.open(profileCode: "prf_a", docCode: nil, title: "x")
        #expect(api.pdfURLRequests.isEmpty)
        #expect(pdf.errorMessage == "The PDF for this statement isn't available.")
    }

    @Test("a missing file reads 'isn't in storage'; other storage errors as the server says")
    func storageErrors() async {
        #expect(StatementPDF.storageMessage("Object not found") == "The PDF file isn't in storage.")
        #expect(StatementPDF.storageMessage("not_found") == "The PDF file isn't in storage.")
        #expect(StatementPDF.storageMessage("new row violates row-level security policy")
                == "new row violates row-level security policy")
        #expect(StatementPDF.storageMessage("") == "Couldn't open the PDF.")

        let api = StubAPI()
        api.pdfURLs[docCode] = .failure(StatementPDF.Failure.storage("Object not found"))
        let pdf = StatementPDF(api: api, fetch: { _ in Data() })
        await pdf.open(profileCode: "prf_a", docCode: docCode, title: "x")
        #expect(pdf.errorMessage == "The PDF file isn't in storage." && pdf.document == nil)
    }

    @Test("an answer that isn't a PDF (an error page) is not shown")
    func notPDF() async {
        let api = StubAPI()
        api.pdfURLs[docCode] = .success(signed)
        let pdf = StatementPDF(api: api, fetch: { _ in Data("<html>expired</html>".utf8) })
        await pdf.open(profileCode: "prf_a", docCode: docCode, title: "x")
        #expect(pdf.document == nil && pdf.errorMessage == "Couldn't open the PDF.")
        #expect(StatementPDF.isPDF(pdfBytes) && !StatementPDF.isPDF(Data()))
    }

    @Test("offline: the API's own message")
    func offline() async {
        let api = StubAPI()
        api.pdfURLs[docCode] = .failure(LedgerAPIError.network("-1009"))
        let pdf = StatementPDF(api: api, fetch: { _ in Data() })
        await pdf.open(profileCode: "prf_a", docCode: docCode, title: "x")
        #expect(pdf.errorMessage == "No connection to Ledger.")
    }

    @Test("the web's bucket and signed-URL lifetime")
    func constants() {
        #expect(StatementPDF.bucket == "statements" && StatementPDF.signedURLSeconds == 120)
    }
}

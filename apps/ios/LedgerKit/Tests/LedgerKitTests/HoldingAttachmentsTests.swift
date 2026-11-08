import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

/// Synthetic attachments: made-up codes, Alice's invoice and a certificate.
enum AttachmentFixtures {
    static let profile = "prf_a"
    static let holding = "hld_01k9z00000000000000000hold"
    static let json = Data(#"""
    {
      "flows": [],
      "valuations": [],
      "attachments": [
        {"attachment_code": "hat_01k9z00000000000000000inv1",
         "storage_path": "prf_a/hld_01k9z00000000000000000hold/0d4c2f7e-1111-4222-8333-944455556666.jpg",
         "file_name": "Photo 8 Nov 2026.jpg", "mime_type": "image/jpeg", "size_bytes": 2400000,
         "caption": "Alice's invoice", "created_at": "2026-11-07T21:30:00.123456+00:00"},
        {"attachment_code": "hat_01k9z00000000000000000crt1",
         "storage_path": "prf_a/hld_01k9z00000000000000000hold/5e6f7a8b-2222-4333-8444-955566667777.pdf",
         "file_name": "Certificate.pdf", "mime_type": "application/pdf", "size_bytes": 81920,
         "caption": null, "created_at": "2026-10-02T06:00:00+00:00"}
      ]
    }
    """#.utf8)

    static func detail() throws -> HoldingDetail { try LedgerJSON.decode(HoldingDetail.self, from: json) }
}

@Suite("Holding attachments: the wire and the rules")
struct HoldingAttachmentRulesTests {
    @Test("holding_detail's attachments decode newest first; a server without the key sends none")
    func decoding() throws {
        let d = try AttachmentFixtures.detail()
        #expect(d.attachments.count == 2 && d.flows.isEmpty && d.valuations.isEmpty)
        let photo = try #require(d.attachments.first)
        #expect(photo.id == "hat_01k9z00000000000000000inv1" && photo.sizeBytes == 2_400_000 && photo.mimeType == "image/jpeg")
        #expect(photo.isImage && !photo.isPDF && photo.systemImage == "photo")
        #expect(photo.label == "Alice's invoice" && photo.sizeText == "2.3 MB")
        // 21:30 UTC on the 7th is 01:30 on the 8th in Dubai.
        #expect(photo.addedText == "8 Nov 2026" && photo.detailText == "8 Nov 2026 · 2.3 MB")
        let cert = d.attachments[1]
        #expect(cert.isPDF && !cert.isImage && cert.caption == nil && cert.label == "Certificate.pdf")
        #expect(cert.detailText == "2 Oct 2026 · 80 KB" && cert.systemImage == "doc.richtext")
        // The fixture predates attachments: no key, no attachments, everything else intact.
        let old = try KindsFixtures.detail()
        #expect(old.attachments.isEmpty && old.flows.count == 9)
        #expect(HoldingDetail().attachments.isEmpty)
    }

    @Test("a blank caption falls back to the file name")
    func label() {
        let a = HoldingAttachment(attachmentCode: "hat_x", storagePath: "p/h/f.pdf", fileName: "Bob's receipt.pdf",
                                  mimeType: "application/pdf", sizeBytes: 10, caption: "  ", createdAt: .now)
        #expect(a.label == "Bob's receipt.pdf")
    }

    @Test("a new file goes to <profile>/<holding>/<uuid>.<ext>, its extension from its type")
    func paths() throws {
        let id = try #require(UUID(uuidString: "0D4C2F7E-1111-4222-8333-944455556666"))
        #expect(HoldingAttachments.storagePath(profileCode: "prf_a", holdingCode: "hld_b", id: id, mimeType: "image/jpeg")
            == "prf_a/hld_b/0d4c2f7e-1111-4222-8333-944455556666.jpg")
        #expect(HoldingAttachments.storagePath(profileCode: "prf_a", holdingCode: "hld_b", id: id, mimeType: "application/pdf")?
            .hasSuffix(".pdf") == true)
        #expect(HoldingAttachments.storagePath(profileCode: "prf_a", holdingCode: "hld_b", id: id, mimeType: "image/heic")?
            .hasSuffix(".heic") == true)
        #expect(HoldingAttachments.storagePath(profileCode: "prf_a", holdingCode: "hld_b", id: id, mimeType: "image/gif") == nil)
        #expect(HoldingAttachments.storagePath(profileCode: "", holdingCode: "hld_b", id: id, mimeType: "image/png") == nil)
        let path = try #require(HoldingAttachments.storagePath(profileCode: "prf_a", holdingCode: "hld_b", id: id, mimeType: "image/png"))
        #expect(path.split(separator: "/").count == 3)
    }

    @Test("types by extension, as the bucket allows them")
    func types() {
        #expect(HoldingAttachments.mimeType(forFileName: "Invoice.PDF") == "application/pdf")
        #expect(HoldingAttachments.mimeType(forFileName: "scan.jpeg") == "image/jpeg")
        #expect(HoldingAttachments.mimeType(forFileName: "a.b.heic") == "image/heic")
        #expect(HoldingAttachments.mimeType(forFileName: "notes.txt") == nil)
        #expect(HoldingAttachments.mimeType(forFileName: "README") == nil)
        #expect(HoldingAttachments.mimeType(forFileName: ".pdf") == nil)
        #expect(HoldingAttachments.isImage("image/webp") && !HoldingAttachments.isImage("application/pdf"))
        #expect(HoldingAttachments.isPDF("application/pdf") && !HoldingAttachments.isPDF("image/png"))
    }

    @Test("sizes read as the web shows them")
    func bytes() {
        #expect(HoldingAttachments.formatBytes(0) == "0 B")
        #expect(HoldingAttachments.formatBytes(512) == "512 B")
        #expect(HoldingAttachments.formatBytes(1024) == "1 KB")
        #expect(HoldingAttachments.formatBytes(81_920) == "80 KB")
        #expect(HoldingAttachments.formatBytes(2_400_000) == "2.3 MB")
        #expect(HoldingAttachments.formatBytes(1_048_576) == "1.0 MB")
        #expect(HoldingAttachments.formatBytes(10_485_760) == "10.0 MB")
        #expect(HoldingAttachments.formatBytes(-1) == "")
    }

    @Test("the phone's checks: type, empty, 10 MB, 20 files")
    func checks() {
        #expect(HoldingAttachments.check(byteCount: 1000, mimeType: "image/jpeg", existing: 0) == nil)
        #expect(HoldingAttachments.check(byteCount: 1000, mimeType: "image/gif", existing: 0) == HoldingAttachments.unsupportedType)
        #expect(HoldingAttachments.check(byteCount: 1000, mimeType: nil, existing: 0) == HoldingAttachments.unsupportedType)
        #expect(HoldingAttachments.check(byteCount: 0, mimeType: "application/pdf", existing: 0) == "The file is empty.")
        #expect(HoldingAttachments.check(byteCount: 10_485_760, mimeType: "application/pdf", existing: 19) == nil)
        #expect(HoldingAttachments.check(byteCount: 10_485_761, mimeType: "application/pdf", existing: 0) == "Files are at most 10 MB.")
        #expect(HoldingAttachments.check(byteCount: 10, mimeType: "image/png", existing: 20) == HoldingAttachments.fullMessage)
    }

    @Test("names: a photo by its day; recorded names cleaned; shared copies end in their type")
    func names() {
        #expect(HoldingAttachments.photoFileName(on: day("2026-11-08")) == "Photo 8 Nov 2026.jpg")
        #expect(HoldingAttachments.cleanFileName("  a/b:c.pdf ", mimeType: "application/pdf") == "a-b-c.pdf")
        #expect(HoldingAttachments.cleanFileName(" ", mimeType: "application/pdf") == "File.pdf")
        #expect(HoldingAttachments.cleanFileName("", mimeType: "image/png") == "Photo.png")
        #expect(HoldingAttachments.cleanFileName(String(repeating: "x", count: 300), mimeType: "image/png").count == 200)
        func a(_ name: String, _ type: String) -> HoldingAttachment {
            HoldingAttachment(attachmentCode: "hat_x", storagePath: "p/h/f", fileName: name, mimeType: type, sizeBytes: 1, createdAt: .now)
        }
        #expect(HoldingAttachments.shareFilename(a("Invoice.PDF", "application/pdf")) == "Invoice.PDF")
        #expect(HoldingAttachments.shareFilename(a("Invoice", "application/pdf")) == "Invoice.pdf")
        #expect(HoldingAttachments.shareFilename(a("scan.jpeg", "image/jpeg")) == "scan.jpeg")
        #expect(HoldingAttachments.shareFilename(a("scan.png", "image/jpeg")) == "scan.png.jpg")
    }

    @Test("a large photo is scaled to 4096 px on its longer side, a small one left alone")
    func photoSize() {
        let big = HoldingAttachments.photoSize(width: 8064, height: 6048)
        #expect(big.width == 4096 && big.height == 3072)
        let tall = HoldingAttachments.photoSize(width: 3000, height: 8192)
        #expect(tall.width == 1500 && tall.height == 4096)
        let small = HoldingAttachments.photoSize(width: 1200, height: 900)
        #expect(small.width == 1200 && small.height == 900)
    }

    @Test("downloaded bytes are a picture only with a picture's signature")
    func imageData() {
        #expect(HoldingAttachments.isImageData(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])))
        #expect(HoldingAttachments.isImageData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
        #expect(HoldingAttachments.isImageData(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)))
        #expect(HoldingAttachments.isImageData(Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))))
        #expect(!HoldingAttachments.isImageData(Data("<html><body>".utf8)))
        #expect(!HoldingAttachments.isImageData(Data("%PDF-1.7".utf8)))
        #expect(!HoldingAttachments.isImageData(Data()))
    }

    @Test("failures in plain words")
    func messages() {
        let m = HoldingAttachments.message(for:)
        #expect(m(LedgerAPIError.server(status: 403, code: "42501", message: "only owners")) == HoldingDraft.ownerOnlyMessage)
        #expect(m(LedgerAPIError.server(status: nil, code: "P0002", message: "attachment not found")) == "That file was already removed.")
        #expect(m(LedgerAPIError.server(status: nil, code: "P0002", message: "the file has not been uploaded"))
            == "The file didn't finish uploading. Try again.")
        #expect(m(LedgerAPIError.server(status: nil, code: "22023", message: "a holding keeps at most 20 attachments"))
            == "A holding keeps at most 20 attachments.")
        #expect(m(HoldingAttachments.Failure.storage("The object exceeded the maximum allowed size")) == "Files are at most 10 MB.")
        #expect(m(HoldingAttachments.Failure.storage("mime type image/gif is not supported")) == HoldingAttachments.unsupportedType)
        #expect(HoldingAttachments.openMessage(for: StatementPDF.Failure.storage("Object not found")) == "The file isn't in storage.")
        #expect(HoldingAttachments.openMessage(for: HoldingAttachments.Failure.unreadable) == "Couldn't open the file.")
    }
}

@Suite("Holding attachments: the screen's model")
@MainActor
struct HoldingAttachmentModelTests {
    let signed = URL(string: "http://127.0.0.1:54321/storage/v1/object/sign/holding-attachments/x?token=t")!
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46])
    let pdf = Data("%PDF-1.7\n1 0 obj\n".utf8)

    func api() throws -> StubAPI {
        let api = StubAPI()
        api.holdingDetailFixture = try AttachmentFixtures.detail()
        return api
    }

    func model(_ api: StubAPI, fetch: @escaping StatementPDF.Fetch = { _ in Data() },
               told: (@MainActor (String) async -> Void)? = nil) -> HoldingDetailModel {
        HoldingDetailModel(holdingCode: AttachmentFixtures.holding, api: api, today: { day("2026-11-08") },
                           onChange: told ?? { _ in }, fetchFile: fetch)
    }

    @Test("the list, its empty state and the owner's note, said only once loaded")
    func list() async throws {
        let api = try api()
        let m = model(api)
        #expect(m.noAttachmentsMessage(canEdit: true) == nil && !m.canAddAttachment(canEdit: true))
        await m.load(profileCode: AttachmentFixtures.profile)
        #expect(m.attachments.map(\.label) == ["Alice's invoice", "Certificate.pdf"])
        #expect(m.noAttachmentsMessage(canEdit: true) == nil && m.canAddAttachment(canEdit: true))
        #expect(!m.canAddAttachment(canEdit: false) && m.attachmentsNote(canEdit: false) == nil)
        #expect(m.attachmentsNote(canEdit: true)?.contains("Swipe") == true)
        api.holdingDetailFixture = HoldingDetail()
        await m.load(profileCode: AttachmentFixtures.profile)
        #expect(m.noAttachmentsMessage(canEdit: true)?.hasPrefix("Add a photo or PDF") == true)
        #expect(m.noAttachmentsMessage(canEdit: false) == "The ledger's owner can add invoices and certificates here.")
        let full = (0..<20).map {
            HoldingAttachment(attachmentCode: "hat_\($0)", storagePath: "p/h/\($0).pdf", fileName: "\($0).pdf",
                              mimeType: "application/pdf", sizeBytes: 1, createdAt: .now)
        }
        api.holdingDetailFixture = HoldingDetail(attachments: full)
        await m.load(profileCode: AttachmentFixtures.profile)
        #expect(!m.canAddAttachment(canEdit: true) && m.attachmentsNote(canEdit: true) == HoldingAttachments.fullMessage)
        #expect(await m.addPhoto(jpeg, profileCode: AttachmentFixtures.profile, canEdit: true) == HoldingAttachments.fullMessage)
        #expect(api.uploadedAttachments.isEmpty)
    }

    @Test("a photo goes up as JPEG under the holding's folder, named by the day; the tab isn't told")
    func addPhoto() async throws {
        let api = try api()
        var told: [String] = []
        let m = model(api, told: { told.append($0) })
        await m.load(profileCode: AttachmentFixtures.profile)
        #expect(await m.addPhoto(jpeg, profileCode: AttachmentFixtures.profile, canEdit: false) == HoldingDraft.ownerOnlyMessage)
        #expect(await m.addPhoto(nil, profileCode: AttachmentFixtures.profile, canEdit: true) == HoldingAttachments.unreadablePhoto)
        #expect(api.uploadedAttachments.isEmpty)
        #expect(await m.addPhoto(jpeg, profileCode: AttachmentFixtures.profile, canEdit: true) == nil)
        let up = try #require(api.uploadedAttachments.last)
        let parts = up.storagePath.split(separator: "/").map(String.init)
        #expect(parts.count == 3 && parts[0] == AttachmentFixtures.profile && parts[1] == AttachmentFixtures.holding)
        #expect(parts[2].hasSuffix(".jpg") && parts[2].count == 36 + 4 && parts[2] == parts[2].lowercased())
        #expect(up.holdingCode == AttachmentFixtures.holding && up.mimeType == "image/jpeg" && up.data == jpeg)
        #expect(up.fileName == "Photo 8 Nov 2026.jpg" && up.caption == nil)
        #expect(m.notice?.text == "Photo 8 Nov 2026.jpg added." && told.isEmpty && !m.isAddingAttachment)
    }

    @Test("a PDF from Files: read, typed by its extension; anything else refused before it goes")
    func addFile() async throws {
        let api = try api()
        let m = model(api)
        await m.load(profileCode: AttachmentFixtures.profile)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Bob's certificate.pdf")
        try pdf.write(to: file)
        #expect(await m.addFile(at: file, profileCode: AttachmentFixtures.profile, canEdit: true) == nil)
        let up = try #require(api.uploadedAttachments.last)
        #expect(up.mimeType == "application/pdf" && up.fileName == "Bob's certificate.pdf" && up.storagePath.hasSuffix(".pdf"))
        let text = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        #expect(await m.addFile(at: text, profileCode: AttachmentFixtures.profile, canEdit: true) == HoldingAttachments.unsupportedType)
        let missing = dir.appendingPathComponent("gone.pdf")
        #expect(await m.addFile(at: missing, profileCode: AttachmentFixtures.profile, canEdit: true) == "Couldn't read gone.pdf.")
        #expect(api.uploadedAttachments.count == 1)
    }

    @Test("a refused upload says why; remove forgets the file, owners only")
    func failuresAndRemove() async throws {
        let api = try api()
        let m = model(api)
        await m.load(profileCode: AttachmentFixtures.profile)
        api.attachmentError = HoldingAttachments.Failure.storage("The object exceeded the maximum allowed size")
        #expect(await m.addPhoto(jpeg, profileCode: AttachmentFixtures.profile, canEdit: true) == "Files are at most 10 MB.")
        api.attachmentError = LedgerAPIError.server(status: nil, code: "P0002", message: "attachment not found")
        let first = try #require(m.attachments.first)
        #expect(await m.removeAttachment(first, profileCode: AttachmentFixtures.profile, canEdit: true) == "That file was already removed.")
        api.attachmentError = nil
        #expect(await m.removeAttachment(first, profileCode: AttachmentFixtures.profile, canEdit: false) == HoldingDraft.ownerOnlyMessage)
        #expect(api.removedAttachments.isEmpty)
        #expect(await m.removeAttachment(first, profileCode: AttachmentFixtures.profile, canEdit: true) == nil)
        #expect(api.removedAttachments == [first.attachmentCode] && m.notice?.text == "Alice's invoice removed.")
        #expect(HoldingAttachments.removeTitle(first) == "Remove Alice's invoice?")
    }

    @Test("opening: a photo or PDF is signed and shown from memory; a missing or wrong file says so")
    func open() async throws {
        let api = try api()
        let detail = try AttachmentFixtures.detail()
        let photo = detail.attachments[0]
        let cert = detail.attachments[1]
        let photoURL = signed.appendingPathComponent("photo")
        let certURL = signed.appendingPathComponent("cert")
        api.attachmentURLs = [photo.storagePath: photoURL, cert.storagePath: certURL]
        let served: [URL: Data] = [photoURL: jpeg, certURL: pdf]
        let viewer = HoldingAttachmentViewer(api: api, fetch: { served[$0] ?? Data() })

        await viewer.open(photo)
        let shown = try #require(viewer.document)
        #expect(!shown.isPDF && shown.data == jpeg && shown.title == "Alice's invoice" && shown.filename == "Photo 8 Nov 2026.jpg")
        #expect(viewer.errorMessage == nil && !viewer.isLoading && viewer.openingCode == nil)
        viewer.close()
        #expect(viewer.document == nil)

        await viewer.open(cert)
        #expect(viewer.document?.isPDF == true && viewer.document?.filename == "Certificate.pdf")
        #expect(api.attachmentURLRequests == [photo.storagePath, cert.storagePath])
        viewer.close()

        // The PDF's URL answers with an error page, not a PDF.
        let wrong = HoldingAttachmentViewer(api: api, fetch: { _ in Data("<html>".utf8) })
        await wrong.open(cert)
        #expect(wrong.document == nil && wrong.errorMessage == "Couldn't open the file.")

        api.attachmentURLs = [:]
        await wrong.open(photo)
        #expect(wrong.errorMessage == "The file isn't in storage.")
    }
}

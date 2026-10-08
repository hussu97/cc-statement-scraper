import Foundation
import Testing
@testable import LedgerKit

@Suite("Upload log: document_events and per-file outcomes", .serialized)
struct UploadLogTests {
    let doc = "doc_01hzy3k8w9m2n4p6q8r0s2t4d1"
    let t0 = Date(timeIntervalSince1970: 1_791_620_000)

    func event(_ code: String, _ stage: String, at seconds: TimeInterval, doc: String? = nil, level: String = "info",
               message: String = "", errorCode: String? = nil) -> DocumentEvent {
        DocumentEvent(eventCode: code, docCode: doc ?? self.doc, createdAt: t0.addingTimeInterval(seconds), stage: stage,
                      level: level, message: message, errorCode: errorCode)
    }

    @Test("document_events rows decode, both timestamp shapes, error_code from detail")
    func decode() throws {
        let rows = try LedgerJSON.decode([DocumentEvent].self, from: try fixture("document_events"))
        #expect(rows.map(\.stage) == ["received", "stored", "queued", "parsing", "failed"])
        #expect(rows[3].createdAt > rows[2].createdAt)
        #expect(rows[4].errorCode == "PDF_DECRYPT_FAILED")
        #expect(rows[0].errorCode == nil)
        #expect(DocumentEvent.ordered(rows.reversed()) == rows)
        #expect(StagePresentation.of(rows[4]) == StagePresentation(label: "Failed", systemImage: "exclamationmark.triangle.fill", tone: .danger))
        #expect(rows[4].timeLabel(today: CalendarDay(iso: "2026-10-10")!) == "12:15")
        #expect(rows[4].timeLabel(today: CalendarDay(iso: "2026-10-11")!) == "10 Oct, 12:15")

        let upload = try LedgerJSON.decode(UploadResponse.self, from: Data("""
            {"uploads": [{"filename": "a.pdf", "doc_code": "doc_1", "status": "duplicate", "parse_status": "queued", "requeued": true},
                         {"filename": "b.pdf", "doc_code": "doc_2", "status": "queued"}]}
            """.utf8))
        #expect(upload.uploads[0].requeued && upload.uploads[0].parseStatus == "queued")
        #expect(!upload.uploads[1].requeued && upload.uploads[1].parseStatus == nil)
    }

    @Test("merge drops Realtime/fetch overlap; the latest attempt starts at the last 'received'")
    func timeline() {
        let first = [event("dev_1", "received", at: 0), event("dev_2", "failed", at: 5)]
        let merged = DocumentEvent.merge(first, [event("dev_2", "failed", at: 5), event("dev_3", "received", at: 60),
                                                 event("dev_4", "duplicate", at: 61)])
        #expect(merged.map(\.eventCode) == ["dev_1", "dev_2", "dev_3", "dev_4"])
        #expect(DocumentEvent.latestAttempt(merged).map(\.eventCode) == ["dev_3", "dev_4"])
    }

    @Test("advice: a wrong password points at the web; unknown codes add nothing")
    func advice() {
        #expect(UploadAdvice.forCode("PDF_DECRYPT_FAILED") == "Set the password on the web: Settings → Statement passwords. Then upload the PDF again.")
        #expect(UploadAdvice.forCode("INGEST_23514")?.contains("web") == true)
        #expect(UploadAdvice.forCode("SOMETHING_NEW") == nil)
        #expect(UploadAdvice.forCode(nil) == nil)
    }

    @Test("status: uploading → sent → reading → imported; failures carry what to do")
    func status() {
        var item = UploadItem(filename: "a.pdf")
        #expect(UploadItemStatus.of(item, events: []).title == "Waiting to upload")
        item.phase = .uploading
        #expect(UploadItemStatus.of(item, events: []).inProgress)
        item.phase = .sent(docCode: doc, duplicate: false, requeued: false, parseStatus: "queued")
        #expect(UploadItemStatus.of(item, events: []).title == "Sent")
        let parsing = [event("dev_1", "received", at: 0), event("dev_2", "parsing", at: 3, message: "Reading the PDF.")]
        let reading = UploadItemStatus.of(item, events: parsing)
        #expect(reading.title == "Reading" && reading.detail == "Reading the PDF." && !reading.isSettled)
        let done = UploadItemStatus.of(item, events: parsing + [event("dev_3", "ingested", at: 9, message: "Imported 1 statement.")])
        #expect(done.title == "Imported" && done.tone == .positive && done.isSettled)
        let failed = UploadItemStatus.of(item, events: parsing + [event("dev_3", "failed", at: 9, level: "error",
                                                                        message: "We couldn't open this PDF.", errorCode: "PDF_DECRYPT_FAILED")])
        #expect(failed.tone == .danger && failed.isSettled)
        #expect(failed.advice?.hasPrefix("Set the password on the web") == true)
        let retrying = UploadItemStatus.of(item, events: parsing + [event("dev_3", "retry", at: 9, level: "warn")])
        #expect(retrying.tone == .warn && !retrying.isSettled)

        item.phase = .sent(docCode: doc, duplicate: true, requeued: false, parseStatus: "parsed")
        #expect(UploadItemStatus.of(item, events: []).title == "Already in Bank Ledger")
        let dup = UploadItemStatus.of(item, events: [event("dev_9", "received", at: 0), event("dev_10", "duplicate", at: 1)])
        #expect(dup.isSettled && dup.title == "Already uploaded")

        item.phase = .rejected("FAB.pdf is larger than 25 MB.")
        let rejected = UploadItemStatus.of(item, events: [])
        #expect(rejected.title == "Not uploaded" && rejected.detail == "FAB.pdf is larger than 25 MB." && rejected.isSettled)
    }

    @Test("session: one request per file, a refused file doesn't stop the rest, Realtime rows move each row")
    @MainActor
    func session() async throws {
        let api = StubAPI()
        api.uploadAnswers = [
            "a.pdf": .success(.init(filename: "a.pdf", docCode: "doc_a", status: "queued", parseStatus: "queued")),
            "big.pdf": .failure(.server(status: 413, code: "FILE_TOO_LARGE", message: "big.pdf exceeds the 25 MB limit")),
            "c.pdf": .success(.init(filename: "c.pdf", docCode: "doc_c", status: "duplicate", parseStatus: "parsed")),
        ]
        api.storedEvents = ["doc_a": [event("dev_a1", "received", at: 0, doc: "doc_a"), event("dev_a2", "queued", at: 1, doc: "doc_a")]]
        let session = UploadSession(api: api, pollInterval: .milliseconds(20), pollLimit: 3)
        let files = ["a.pdf", "big.pdf", "c.pdf"].map { UploadFile(filename: $0, data: Data("%PDF".utf8)) }
        await session.upload(files, profileCode: "prf_a")

        #expect(api.uploadedFilenames == ["a.pdf", "big.pdf", "c.pdf"])
        let statuses = session.items.map(session.status(of:))
        #expect(statuses.map(\.title) == ["Waiting", "Not uploaded", "Already in Bank Ledger"])
        #expect(statuses[1].detail == "big.pdf exceeds the 25 MB limit")
        #expect(session.isActive)
        #expect(session.summary == "1 of 3 done · 1 failed")

        api.eventFeed.continuation.yield(event("dev_a3", "parsing", at: 5, doc: "doc_a"))
        api.eventFeed.continuation.yield(event("dev_a4", "ingested", at: 9, doc: "doc_a", message: "Imported 1 statement."))
        api.eventFeed.continuation.yield(event("dev_z1", "received", at: 9, doc: "doc_other"))
        for _ in 0..<50 where session.isActive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.status(of: session.items[0]).title == "Imported")
        #expect(session.timeline(of: session.items[0]).map(\.stage) == ["received", "queued", "parsing", "ingested"])
        #expect(!session.isActive)

        session.clearFinished()
        #expect(session.isEmpty)
        #expect(session.events.isEmpty)
    }

    @Test("document log: initial fetch, live rows for this document only, advice from the failure")
    @MainActor
    func documentLog() async throws {
        let api = StubAPI()
        let rows = try LedgerJSON.decode([DocumentEvent].self, from: try fixture("document_events"))
        api.storedEvents = [doc: Array(rows.prefix(4))]
        let record = try LedgerJSON.decode(DocumentRecord.self, from: Data("""
            {"doc_code": "\(doc)", "kind": null, "bank_code": "FAB", "original_filename": "fab.pdf", "source": "ios",
             "parse_status": "parsing", "parse_error_code": null, "parse_error": null,
             "created_at": "2026-10-10T08:15:02+00:00", "parsed_at": null}
            """.utf8))
        let log = DocumentLogModel(api: api, document: record)
        await log.start(profileCode: "prf_a")
        #expect(log.events.count == 4)
        #expect(log.advice == nil)
        api.eventFeed.continuation.yield(rows[4])
        api.eventFeed.continuation.yield(event("dev_x", "received", at: 0, doc: "doc_other"))
        for _ in 0..<50 where log.events.count < 5 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.events.map(\.stage).last == "failed")
        #expect(log.events.count == 5)
        #expect(log.advice?.hasPrefix("Set the password on the web") == true)
        log.stop()
    }

    @Test("IOS-16r: a permanently refused PDF is set aside with its reason; the rest still go")
    func pendingQuarantine() async throws {
        let pending = PendingUploads(container: FileManager.default.temporaryDirectory.appendingPathComponent("ledger-q-\(UUID().uuidString)"))
        try pending.save(UploadFile(filename: "bad.pdf", data: Data("%PDF-bad".utf8)))
        try pending.save(UploadFile(filename: "good.pdf", data: Data("%PDF-good".utf8)))
        #expect(pending.waitingLabel == "2 PDFs waiting to upload")

        let sent = await pending.flush(profileCode: "prf_a") { file in
            if file.filename == "bad.pdf" {
                throw LedgerAPIError.server(status: 413, code: "FILE_TOO_LARGE", message: "bad.pdf exceeds the 25 MB limit")
            }
            return UploadResponse(uploads: [.init(filename: file.filename, docCode: "doc_x", status: "queued")])
        }
        #expect(sent == 1)
        #expect(pending.count == 0)
        #expect(pending.waitingLabel == nil)
        let rejected = pending.rejected()
        #expect(rejected.map(\.filename) == ["bad.pdf"])
        #expect(rejected[0].reason == "bad.pdf exceeds the 25 MB limit")
        pending.discard(rejected[0])
        #expect(pending.rejected().isEmpty)

        // A transient failure still stops the run and keeps the file.
        try pending.save(UploadFile(filename: "later.pdf", data: Data("%PDF".utf8)))
        _ = await pending.flush(profileCode: "prf_a") { _ in throw LedgerAPIError.network("offline") }
        #expect(pending.waitingLabel == "1 PDF waiting to upload")
        #expect(pending.rejected().isEmpty)
    }
}

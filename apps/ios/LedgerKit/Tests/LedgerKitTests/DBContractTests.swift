import Foundation
import Testing
@testable import LedgerKit

/// Client side of the 42a95f1 DB contract: terminal `ingest_sms` statuses,
/// `resolve_review` errors and `not_a_transaction`, `retry_sms_fallback`,
/// and recon `n/a` for history extracts.
@Suite("ingest_sms — 'invalid' and 'failed' are terminal")
struct IngestTerminalStatusTests {
    let profile = "prf_01hzy3k8w9m2n4p6q8r0s2t4v6"

    func payload(_ n: Int) -> SMSPayload {
        SMSPayload(receivedAt: Date(timeIntervalSince1970: 1_791_436_364 + Double(n)), sender: "FAB",
                   body: "Purchase of AED \(n).00 with Credit Card ending 1234")
    }

    /// Answers each message with `status` (+ `reason`) for the first body, `new` for the rest.
    func api(firstStatus status: String, reason: String, smsCode: String?) -> StubAPI {
        StubAPI(.custom { _, messages in
            messages.enumerated().map { i, m in
                SMSIngestResult(clientMsgId: m.clientMsgId.uuidString.lowercased(),
                                smsCode: i == 0 ? smsCode : "sms_ok",
                                status: i == 0 ? status : "new", txnCode: nil, reason: i == 0 ? reason : nil)
            }
        })
    }

    @Test("'invalid' (not stored): parked with the reason in words, the rest delivered, never re-sent")
    func invalidIsTerminal() async throws {
        let stub = api(firstStatus: "invalid", reason: "body_too_long", smsCode: nil)
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: stub)
        try await outbox.enqueue([payload(1), payload(2)], profileCode: profile)

        let report = await outbox.flush()
        #expect(report.sent == 2)
        #expect(report.remaining == 0)
        let parked = await outbox.parkedEntries()
        #expect(parked.count == 1)
        #expect(parked[0].payload.body.contains("AED 1.00"))
        let row = ParkedMessage(parked[0])
        #expect(row.reason == "Ledger rejected this message: it's longer than 2,000 characters.")

        // Parked entries are never retried automatically, even on a forced flush.
        await outbox.flush(force: true)
        #expect(stub.sentMessageCount == 2)
        #expect(await outbox.status().parked == 1)
        #expect(await outbox.status().pending == 0)
    }

    @Test("'failed' (stored, processing raised): parked with the SQLSTATE, never re-sent automatically")
    func failedIsTerminal() async throws {
        let stub = api(firstStatus: "failed", reason: "error:22P02", smsCode: "sms_kept")
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: stub)
        try await outbox.enqueue([payload(1), payload(2)], profileCode: profile)

        let report = await outbox.flush()
        #expect(report.parked.count == 1)
        let parked = try #require(await outbox.parkedEntries().first)
        let reason = ParkedMessage(parked).reason
        #expect(reason.contains("saved this message but couldn't process it (error 22P02)"))
        #expect(reason.contains("SMS formats change"))

        await outbox.flush(force: true)
        #expect(stub.sentMessageCount == 2)
        #expect(await outbox.status().pending == 0)
    }

    @Test("result wording: invalid codes, unknown reasons, failed without a code")
    func wording() {
        func r(_ status: String, _ reason: String?) -> SMSIngestResult {
            SMSIngestResult(clientMsgId: "x", smsCode: nil, status: status, txnCode: nil, reason: reason)
        }
        #expect(r("invalid", "missing_body").isFailure)
        #expect(r("failed", "error:P0001").isFailure)
        #expect(r("invalid", "missing_body").failureReason == "Ledger rejected this message: it has no text.")
        #expect(r("invalid", "invalid_received_at").failureReason == "Ledger rejected this message: its received time isn't valid.")
        #expect(r("invalid", "something_new").failureReason == "Ledger rejected this message: something_new")
        #expect(r("invalid", nil).failureReason == "Ledger rejected this message (invalid).")
        #expect(r("failed", nil).failureReason.hasPrefix("Ledger saved this message but couldn't process it. "))
        #expect(!r("unparsed", nil).isFailure)
        #expect(!r("duplicate_delivery", nil).isFailure)
    }

    @Test("decodes a 'failed' result from the server's JSON")
    func decodesFailed() throws {
        let json = #"[{"client_msg_id":"6f1c2a8e-8a0b-4f7e-9d61-2c1f6a3b9e10","sms_code":"sms_1","status":"failed","reason":"error:22P02"}]"#
        let results = try LedgerJSON.decode([SMSIngestResult].self, from: Data(json.utf8))
        #expect(results[0].isFailure)
        #expect(results[0].smsCode == "sms_1")
        #expect(results[0].reason == "error:22P02")
    }
}

@Suite("Review — not a transaction, retry with AI, friendly errors")
struct ReviewContractTests {
    @Test("unparsed SMS without a proposed format: retry with AI, not a card transaction, dismiss")
    func unparsedWithoutTemplate() {
        let review = MatchReview(reviewCode: "rev_1", subjectType: "sms", subjectCode: "sms_1", reason: "unparsed_sms")
        let item = ReviewPresentation.item(review, inbox: ReviewInbox(reviews: [review]))
        #expect(item.options.map(\.action) == [.retryWithAI, .notATransaction, .dismiss])
        #expect(item.options.map(\.label) == ["Retry with AI", "Not a card transaction", "Dismiss"])
        #expect(item.note == nil)
    }

    @Test("unparsed SMS with a proposed format: the proposal is for the web; not a transaction still offered")
    func unparsedWithTemplate() {
        let review = MatchReview(reviewCode: "rev_2", subjectType: "sms", subjectCode: "sms_2", reason: "unparsed_sms",
                                 candidates: [.init(txnCode: nil, bankCode: "FAB", last4: nil, templateCode: "tpl_1")])
        let item = ReviewPresentation.item(review, inbox: ReviewInbox(reviews: [review]))
        #expect(item.options.map(\.action) == [.notATransaction, .dismiss])
        #expect(item.note?.contains("web") == true)
    }

    @Test("unknown card SMS can be marked as not a card transaction")
    func unknownCard() {
        let review = MatchReview(reviewCode: "rev_3", subjectType: "sms", subjectCode: "sms_3", reason: "unknown_card")
        let item = ReviewPresentation.item(review, inbox: ReviewInbox(reviews: [review]))
        #expect(item.options.map(\.action) == [.notATransaction, .dismiss])
    }

    @Test("outcomes in words")
    func outcomes() {
        #expect(ReviewPresentation.outcomeMessage("ignored") == "Marked as not a card transaction.")
        #expect(ReviewPresentation.outcomeMessage("retrying").hasPrefix("Sent to the AI again"))
    }

    @Test("P0002 and 22023 become sentences", arguments: [
        ("P0002", "review rev_1 is not open", "already answered"),
        ("P0002", "unknown transaction txn_x", "no longer exists in this ledger"),
        ("22023", "transaction txn_x is on a different account", "different card account"),
        ("22023", "transaction txn_x is not on this message's account", "different card account"),
        ("22023", "sms sms_1 is already part of a transaction", "already part of a transaction"),
        ("22023", "review rev_1 is not an open unparsed_sms review", "sent to the AI again"),
        ("22023", "unsupported action", "doesn't fit this review"),
    ])
    func errors(code: String, message: String, expected: String) {
        let text = ReviewPresentation.errorMessage(LedgerAPIError.server(status: nil, code: code, message: message))
        #expect(text.contains(expected))
    }

    @Test("the model shows the friendly error and reloads")
    @MainActor
    func modelError() async {
        let stub = StubAPI()
        stub.resolveError = .server(status: nil, code: "P0002", message: "review rev_1 is not open")
        let review = MatchReview(reviewCode: "rev_1", subjectType: "sms", subjectCode: "sms_1", reason: "unparsed_sms")
        let model = ReviewModel(api: stub)
        let item = ReviewPresentation.item(review, inbox: ReviewInbox(reviews: [review]))
        await model.resolve(item, item.options[1], profileCode: "prf_a")
        #expect(model.message?.contains("already answered") == true)
        #expect(stub.resolved.first?.1 == .notATransaction)
    }
}

@Suite("Statements — recon 'n/a' for history extracts")
struct ReconNotApplicableTests {
    @Test("'n/a' is a neutral chip, not an error or 'not reconciled'")
    func notApplicable() throws {
        let json = """
        [{"stmt_code":"stm_h","account_code":"acc_1","bank_code":"SIB","card_last4":null,"kind":"history_extract",
          "statement_date":"2026-09-01","period_start":"2026-08-01","period_end":"2026-09-01","due_date":null,
          "closing_balance":null,"min_due":null,"credit_limit":null,"utilisation":null,"line_count":12,
          "debits":340.5,"credits":0,"recon_status":"n/a",
          "recon_checks":{"line_count":12,"sum_debits":"340.50","sum_credits":"0","held_lines":0,"sms_coverage":null},
          "doc_code":"doc_h"},
         {"stmt_code":"stm_s","account_code":"acc_1","bank_code":"SIB","card_last4":"1234","kind":"statement",
          "statement_date":"2026-09-25","period_start":"2026-08-26","period_end":"2026-09-25","due_date":null,
          "closing_balance":100,"min_due":null,"credit_limit":null,"utilisation":null,"line_count":0,
          "debits":0,"credits":0,"recon_status":"warn",
          "recon_checks":{"line_count":0,"held_lines":0,"unpriced_lines":2,"no_lines":true,"superseded_lines":3},
          "doc_code":"doc_s"}]
        """
        let cycles = try LedgerJSON.decode([StatementCycle].self, from: Data(json.utf8))
        #expect(cycles[0].chips == [ReconChip(label: "Nothing to reconcile", tone: .neutral)])
        #expect(cycles[0].kindLabel == "History extract")
        #expect(cycles[1].chips.map(\.label) == ["Check", "No lines read", "2 awaiting FX"])
        #expect(cycles[1].chips.map(\.tone) == [.warn, .warn, .info])
    }
}

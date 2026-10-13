import Foundation
import Testing
@testable import LedgerKit

/// A `v_transactions` row with the fields the detail sheet reads.
func detailTxn(_ overrides: [String: Any?] = [:]) -> LedgerTransaction {
    var json: [String: Any?] = [
        "txn_code": "txn_1", "profile_code": "prf_a", "account_code": "acc_1", "card_code": "crd_1",
        "status": "posted", "kind": "purchase", "direction": "debit", "txn_date": "2026-10-08",
        "txn_at": "2026-10-08T10:15:00+00:00", "posting_date": "2026-10-10", "stmt_code": nil,
        "merchant_code": "mer_1", "description": "AMAZON US", "merchant_name": "Amazon",
        "amount_original": 12, "currency_original": "USD", "amount_aed": "44.07", "amount_aed_is_estimate": true,
        "fx_rate": 3.6725, "auth_amount": nil, "amount_source": "sms", "related_txn_code": nil,
        "exclude_from_spend": false, "notes": nil, "category_code": nil, "category_name": nil,
        "category_color": nil, "category_kind": nil, "category_source": nil, "bank_code": "FAB",
        "card_last4": "1234", "account_nickname": "Daily", "has_sms": true, "has_statement": true,
    ]
    for (k, v) in overrides { json[k] = v }
    let data = try! JSONSerialization.data(withJSONObject: json.mapValues { $0 ?? NSNull() })
    return try! LedgerJSON.decode(LedgerTransaction.self, from: data)
}

func evidence(_ json: String) -> [EvidenceItem] {
    try! LedgerJSON.decode([EvidenceItem].self, from: Data(json.utf8))
}

let evidenceJSON = #"""
[{"evidence_code": "evd_line", "evidence_type": "statement_line", "role": "post", "method": "scored", "score": 85.4,
  "is_active": true, "is_locked": false, "created_at": "2026-10-10T08:00:00+00:00",
  "statement_lines": {"line_code": "lin_1", "stmt_code": "stm_1", "txn_date": "2026-10-08", "posting_date": "2026-10-10",
    "description_raw": "AMAZON US SEATTLE", "amount_original": 12.00, "currency_original": "USD", "amount_aed": 44.07,
    "statements": {"statement_date": "2026-10-25", "kind": "statement"}},
  "sms_messages": null},
 {"evidence_code": "evd_sms", "evidence_type": "sms", "role": "primary", "method": "new", "score": null,
  "is_active": true, "is_locked": true, "created_at": "2026-10-08T10:16:00+00:00", "statement_lines": null,
  "sms_messages": {"sms_code": "sms_1", "received_at": "2026-10-08T10:15:30+00:00", "event_at": "2026-10-08T10:15:00+00:00",
    "sender": "FAB", "msg_kind": "purchase", "amount": 12.00, "currency": "USD", "card_last4": "1234"}},
 {"evidence_code": "evd_old", "evidence_type": "sms", "role": "duplicate", "method": "exact", "score": 100,
  "is_active": false, "is_locked": false, "created_at": "2026-10-01T10:16:00+00:00", "statement_lines": null,
  "sms_messages": {"sms_code": "sms_0", "received_at": "2026-10-01T10:15:30+00:00", "event_at": null,
    "sender": "FAB", "msg_kind": null, "amount": null, "currency": null, "card_last4": null}}]
"""#

@Suite("Transaction detail sheet: badges, merchant context, evidence, SMS text (PAR-2)")
struct TransactionDetailTests {
    @Test("badges, time, posted date, card and FX lines read as the web drawer's")
    func presentation() {
        let t = detailTxn()
        #expect(t.detailBadges.map(\.label) == ["Purchase", "SMS + statement", "AED estimated"])
        #expect(t.whenLabel == "8 Oct 2026, 14:15")                   // Dubai time
        #expect(t.postedLabel == "10 Oct 2026")
        #expect(t.cardDetail == "FAB •1234 · Daily")
        #expect(t.foreignAmountLine == "USD 12.00 @ 3.6725")
        #expect(t.authorisedLine == nil && t.relatedTitle == "Reversed by")

        let awaiting = detailTxn(["amount_aed": nil, "amount_aed_is_estimate": false, "fx_rate": nil, "status": "pending",
                                  "kind": "cash_advance", "has_statement": false, "exclude_from_spend": true,
                                  "txn_at": nil, "posting_date": nil, "auth_amount": 11.5, "related_txn_code": "txn_0"])
        #expect(awaiting.detailBadges == [
            DetailBadge(label: "Cash Advance", tone: .neutral),
            DetailBadge(label: "SMS", tone: .neutral), DetailBadge(label: "Awaiting FX rate", tone: .warn),
            DetailBadge(label: "Excluded from spend", tone: .info),
        ])
        #expect(awaiting.whenLabel == "8 Oct 2026" && awaiting.postedLabel == nil)
        #expect(awaiting.foreignAmountLine == "USD 12.00" && awaiting.authorisedLine == "USD 11.50 at the time of the SMS")
        #expect(awaiting.relatedTitle == "Reverses")
        #expect(detailTxn(["currency_original": "AED", "fx_rate": nil]).foreignAmountLine == nil)
        #expect(detailTxn(["status": "orphaned"]).detailBadges.first == DetailBadge(label: "Orphaned", tone: .danger))
    }

    @Test("merchant context: the web's line from the server's figures; no visit says nothing")
    func merchantLine() throws {
        func ctx(_ json: String) throws -> MerchantContext { try LedgerJSON.decode(MerchantContext.self, from: Data(json.utf8)) }
        let many = try ctx(#"{"merchant_code": "mer_1", "visit_count": 1300, "avg_aed": "254.40", "total_6m_aed": "3306.00", "first_seen": "2024-03-02"}"#)
        #expect(many.line == "1,300 visits · avg AED 254 · AED 3,306 in 6 months · since 2 Mar 2024")
        let first = try ctx(#"{"merchant_code": "mer_1", "visit_count": 1, "avg_aed": "40.00", "total_6m_aed": "0.40", "first_seen": "2026-10-08"}"#)
        #expect(first.line == "First visit · AED 0.40 in 6 months")
        let none = try ctx(#"{"merchant_code": "mer_1", "visit_count": 0, "avg_aed": null, "total_6m_aed": "-20.00", "first_seen": null}"#)
        #expect(none.line == nil)
        #expect(MoneyFormat.total(Decimal(string: "-40.6")!) == "−AED 41")
    }

    @Test("evidence: attached first then oldest first; the web's words for type, role and method")
    func evidenceWords() {
        let items = EvidenceItem.sorted(evidence(evidenceJSON))
        #expect(items.map(\.evidenceCode) == ["evd_sms", "evd_line", "evd_old"])
        let sms = items[0], line = items[1], old = items[2]
        #expect(sms.title == "Bank SMS" && sms.roleLabel == "created the transaction" && sms.isSMS)
        #expect(sms.whenLabel == "8 Oct 2026, 14:15 · new")
        #expect(sms.smsHeader == "From FAB · received 8 Oct 2026, 14:15")
        #expect(sms.smsDetail == "USD 12.00 · purchase · •1234")
        #expect(line.title == "Statement line" && line.roleLabel == "posted")
        #expect(line.whenLabel == "10 Oct 2026 · scored match (85)")
        #expect(line.lineSummary == "USD 12.00 → AED 44.07 · statement of 25 Oct 2026")
        #expect(old.methodLabel == "exact match (100)" && old.smsDetail == nil && !old.isActive)
        #expect(EvidenceItem.select.contains("sms_messages(") && !EvidenceItem.select.contains("body"))
    }

    @Test("the reversal pair filter asks both directions")
    func relatedFilter() {
        #expect(detailTxn().relatedFilter == "related_txn_code.eq.txn_1")
        #expect(detailTxn(["related_txn_code": "txn_0"]).relatedFilter == "related_txn_code.eq.txn_1,txn_code.eq.txn_0")
    }

    @MainActor
    @Test("the model loads context, pair and evidence; an SMS text is read only when opened, and dropped when closed")
    func model() async {
        let api = StubAPI()
        let t = detailTxn()
        api.merchantContexts["mer_1"] = try! LedgerJSON.decode(MerchantContext.self, from: Data(
            #"{"merchant_code": "mer_1", "visit_count": 2, "avg_aed": "40.00", "total_6m_aed": "80.00", "first_seen": "2026-09-01"}"#.utf8))
        api.evidenceRows["txn_1"] = evidence(evidenceJSON)
        api.transactionRows["prf_a"] = [t, detailTxn(["txn_code": "txn_r", "direction": "credit", "related_txn_code": "txn_1"])]
        api.smsBodies["sms_1"] = "Purchase of USD 12.00 at AMAZON"
        let model = TransactionDetailModel(transaction: t, profileCode: "prf_a", api: api)
        await model.load()
        #expect(model.merchantLine == "2 visits · avg AED 40 · AED 80 in 6 months · since 1 Sep 2026")
        #expect(model.related.map(\.txnCode) == ["txn_r"])
        #expect(model.evidence.value?.count == 3 && model.noEvidenceMessage == nil)
        #expect(api.smsBodyReads.isEmpty)                              // never preloaded

        await model.toggleSMS("sms_1")
        #expect(model.openSMS["sms_1"]?.value == "Purchase of USD 12.00 at AMAZON" && model.isOpen("sms_1"))
        await model.toggleSMS("sms_1")
        #expect(model.openSMS.isEmpty)
        await model.toggleSMS("sms_1")                                 // read again on reopening
        #expect(api.smsBodyReads == ["sms_1", "sms_1"])
        model.closeAllSMS()
        #expect(model.openSMS.isEmpty)
    }

    @MainActor
    @Test("no merchant: no context read; no evidence: the orphaned note; a failed context says so")
    func modelEdges() async {
        let api = StubAPI()
        let model = TransactionDetailModel(transaction: detailTxn(["merchant_code": nil]), profileCode: "prf_a", api: api)
        await model.load()
        #expect(!model.hasMerchant && api.calls("merchantContext") == 0)
        #expect(model.noEvidenceMessage?.hasPrefix("No evidence is attached.") == true)

        let failing = TransactionDetailModel(transaction: detailTxn(), profileCode: "prf_a", api: api)
        api.evidenceError = .network("-1009")
        await failing.load()
        #expect(failing.merchantFailed && failing.merchantLine == nil)
        #expect(failing.evidence.errorMessage != nil && failing.noEvidenceMessage == nil)
    }
}

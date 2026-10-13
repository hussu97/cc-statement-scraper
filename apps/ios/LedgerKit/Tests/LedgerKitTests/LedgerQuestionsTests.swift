import Foundation
import Testing
@testable import LedgerKit

@Suite("App Intents beyond SMS: spend, what's due, categorise the last purchase (N-3)")
struct LedgerQuestionsTests {
    func questions(_ api: StubAPI, profile: String? = "prf_a", saved: WidgetSnapshot? = nil) -> LedgerQuestions {
        LedgerQuestions(api: api, profileCode: { profile }, snapshot: { saved })
    }

    func api() throws -> StubAPI {
        let api = StubAPI()
        api.overviewFixture = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        return api
    }

    @Test("spend comes from the server's overview, worded like the hero, named after the saved ledger")
    func spend() async throws {
        let api = try api()
        let answer = await questions(api, saved: try widgetSnapshot(name: "Home")).monthSpend(now: widgetNow)
        #expect(answer.value == "1234567.89")
        #expect(answer.dialog == "You've spent AED 1,234,568 in October so far in Home, 18% below the same day last month.")
        #expect(api.overviewMonths == [nil])
        #expect(!answer.dialog.contains("iPhone"))
    }

    @Test("offline: the saved snapshot of the same ledger answers, and says how old it is")
    func offline() async throws {
        let api = try api()
        api.overviewError = .network("-1009")
        let saved = try widgetSnapshot()
        let answer = await questions(api, saved: saved).monthSpend(now: widgetNow.addingTimeInterval(3600))
        #expect(answer.dialog.hasPrefix("Offline, as of 12:00: You've spent AED 1,234,568 in October"))

        // Another ledger's snapshot is never used.
        let other = await questions(api, profile: "prf_b", saved: saved).monthSpend(now: widgetNow)
        #expect(other.value == nil)
        #expect(other.dialog == "No connection to Bank Ledger, and nothing is saved on this device yet.")
    }

    @Test("signed out, no ledger chosen, or a saved month that is over")
    func failures() async throws {
        let api = try api()
        api.overviewError = .notSignedIn
        #expect(await questions(api).monthSpend(now: widgetNow).dialog == "You are signed out. Open Bank Ledger to sign in.")
        #expect(await questions(api, profile: nil).whatsDue(now: widgetNow).dialog == LedgerQuestions.noLedger)
        let november = CalendarDay(year: 2026, month: 11, day: 2).startDate
        api.overviewError = .network("-1009")
        let stale = await questions(api, saved: try widgetSnapshot()).monthSpend(now: november)
        #expect(stale.value == nil && stale.dialog.contains("nothing saved for November"))
    }

    @Test("what's due: soonest first, balance, date and minimum; at most three, then a count")
    func due() async throws {
        let api = try api()
        let answer = await questions(api).whatsDue(now: widgetNow)
        #expect(answer.count == 1)
        #expect(answer.dialog == "FAB Cashback: AED 4,210.55 due in 7 days (20 Oct), minimum AED 210.53.")

        let cards = (1...5).map { card("c\($0)", due: "2026-10-\(13 + $0)") } + [card("x", due: nil, balance: nil)]
        let many = LedgerQuestions(api: api, profileCode: { "prf_a" }, snapshot: { snapshot(cards: cards) })
        api.overviewError = .network("-1009")
        let listed = await many.whatsDue(now: widgetNow)
        #expect(listed.count == 5)
        #expect(listed.dialog.hasPrefix("Offline, as of 12:00: Card c1: AED 100.00 due tomorrow (14 Oct)."))
        #expect(listed.dialog.hasSuffix("And 2 more in Bank Ledger."))
    }

    @Test("nothing due is said only when statements prove it")
    func nothingDue() async throws {
        let api = StubAPI()
        api.overviewError = .network("-1009")
        let past = LedgerQuestions(api: api, profileCode: { "prf_a" },
                                   snapshot: { snapshot(cards: [card("a", due: "2026-10-01")]) })
        #expect(await past.whatsDue(now: widgetNow).dialog.hasSuffix("Nothing is due: every statement's due date has passed."))
        let none = LedgerQuestions(api: api, profileCode: { "prf_a" }, snapshot: { snapshot(cards: [card("a", due: nil)]) })
        #expect(await none.whatsDue(now: widgetNow).dialog.hasSuffix("No statements yet, so nothing is due."))
    }

    @Test("categorise: the newest purchase, for that transaction only; refunds and payments skipped")
    func categorise() async throws {
        let api = StubAPI()
        let refund = try decodeTxn(code: "txn_refund", kind: "refund")
        api.transactionRows["prf_a"] = [refund, txn("txn_new", merchant: nil), txn("txn_old")]
        let answer = await questions(api).categoriseLast(categoryCode: "cat_food", categoryName: "Groceries")
        #expect(answer.txnCode == "txn_new")
        #expect(answer.dialog.hasPrefix("Filed SHOP txn_new (AED 10.00, "))
        #expect(answer.dialog.hasSuffix(") under Groceries."))
        #expect(api.recategorised.count == 1)
        #expect(api.recategorised.first?.txn == "txn_new" && api.recategorised.first?.category == "cat_food")
        #expect(api.recategorised.first?.merchant == false)
        #expect(api.transactionRequests.first?.query == ActivityQuery())
        #expect(api.transactionRequests.first?.page == PageRequest(offset: 0, limit: 20))
    }

    @Test("categorise: already filed there, nothing to file, or no permission")
    func categoriseEdges() async throws {
        let api = StubAPI()
        api.transactionRows["prf_a"] = [txn("txn_1", category: "cat_food")]
        let same = await questions(api).categoriseLast(categoryCode: "cat_food", categoryName: "Groceries")
        #expect(same.dialog.hasSuffix("is already under Groceries.") && api.recategorised.isEmpty)

        api.transactionRows["prf_a"] = [try decodeTxn(code: "txn_pay", kind: "payment")]
        #expect(await questions(api).categoriseLast(categoryCode: "c", categoryName: "C").dialog
                == "There's no recent purchase to categorise.")

        api.transactionRows["prf_a"] = [txn("txn_1")]
        api.transactionWriteError = .server(status: 403, code: "42501", message: "denied")
        #expect(await questions(api).categoriseLast(categoryCode: "c", categoryName: "C").dialog
                == "You don't have permission to change this ledger (only owners can).")
        #expect(await questions(api, profile: nil).categoriseLast(categoryCode: "c", categoryName: "C").dialog
                == LedgerQuestions.noLedger)
    }

    @Test("categorise: a void or orphaned purchase is skipped for the newest real one", arguments: ["void", "orphaned"])
    func categoriseSkipsDeadPurchases(status: String) async throws {
        let api = StubAPI()
        let json = """
        {"txn_code":"txn_dead","profile_code":"prf_a","account_code":"acc_a","status":"\(status)","kind":"purchase",
         "direction":"debit","txn_date":"2026-10-05","description":"GONE","merchant_name":"Gone",
         "amount_original":"10.00","currency_original":"AED","amount_aed":"10.00","bank_code":"FAB"}
        """
        let dead = try LedgerJSON.decode(LedgerTransaction.self, from: Data(json.utf8))
        #expect(dead.status == status)
        api.transactionRows["prf_a"] = [dead, txn("txn_live")]
        let answer = await questions(api).categoriseLast(categoryCode: "cat_food", categoryName: "Groceries")
        #expect(answer.txnCode == "txn_live")
        #expect(api.recategorised.map(\.txn) == ["txn_live"])

        api.transactionRows["prf_a"] = [dead]
        #expect(await questions(api).categoriseLast(categoryCode: "c", categoryName: "C").dialog
                == "There's no recent purchase to categorise.")
    }

    @Test("the category picker lists the ledger's categories that aren't archived")
    func categories() async throws {
        let api = StubAPI()
        api.categoryOptions = [
            FilterMeta.CategoryOption(categoryCode: "cat_a", name: "Groceries", kind: "expense", colorToken: nil,
                                      parentCode: nil, archived: false),
            FilterMeta.CategoryOption(categoryCode: "cat_b", name: "Old", kind: "expense", colorToken: nil,
                                      parentCode: nil, archived: true),
        ]
        #expect(try await questions(api).categories().map(\.categoryCode) == ["cat_a"])
        await #expect(throws: LedgerAPIError.noProfile) { try await questions(api, profile: nil).categories() }
    }
}

/// A `v_transactions` row of another kind (refund, payment).
func decodeTxn(code: String, kind: String) throws -> LedgerTransaction {
    try LedgerJSON.decode(LedgerTransaction.self, from: transactionJSON(code: code, kind: kind))
}

/// The `txn(_:)` row with another `kind`.
func transactionJSON(code: String, kind: String) -> Data {
    let json: [String: Any?] = [
        "txn_code": code, "profile_code": "prf_a", "account_code": "acc_1", "card_code": nil,
        "status": "posted", "kind": kind, "direction": "credit", "txn_date": "2026-10-02", "txn_at": nil,
        "posting_date": nil, "stmt_code": nil, "merchant_code": nil, "description": "ROW \(code)",
        "merchant_name": nil, "amount_original": "10.00", "currency_original": "AED", "amount_aed": "10.00",
        "amount_aed_is_estimate": false, "fx_rate": nil, "auth_amount": nil, "amount_source": "sms",
        "related_txn_code": nil, "exclude_from_spend": false, "notes": nil, "category_code": nil,
        "category_name": nil, "category_color": nil, "category_kind": nil, "category_source": nil,
        "bank_code": "FAB", "card_last4": "1234", "account_nickname": nil, "has_sms": true, "has_statement": false,
    ]
    return try! JSONSerialization.data(withJSONObject: json.mapValues { $0 ?? NSNull() })
}

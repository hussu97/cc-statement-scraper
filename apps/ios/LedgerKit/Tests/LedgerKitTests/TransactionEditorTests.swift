import Foundation
import Testing
@testable import LedgerKit

/// A `v_transactions` row with the fields the sheet decides on.
private func row(_ code: String = "txn_1", merchant: String? = "mer_x", category: String? = nil, source: String? = nil,
                 excluded: Bool = false, notes: String? = nil) -> LedgerTransaction {
    let json: [String: Any?] = [
        "txn_code": code, "profile_code": "prf_a", "account_code": "acc_1", "status": "posted", "kind": "purchase",
        "direction": "debit", "txn_date": "2026-10-01", "merchant_code": merchant, "description": "SHOP \(code)",
        "merchant_name": merchant == nil ? nil : "Carrefour", "amount_original": "10.00", "currency_original": "AED",
        "amount_aed": "10.00", "exclude_from_spend": excluded, "notes": notes, "category_code": category,
        "category_name": category.map { "Name \($0)" }, "category_source": source, "bank_code": "FAB",
    ]
    let data = try! JSONSerialization.data(withJSONObject: json.mapValues { $0 ?? NSNull() })
    return try! LedgerJSON.decode(LedgerTransaction.self, from: data)
}

private func option(_ code: String, _ name: String) -> FilterMeta.CategoryOption {
    FilterMeta.CategoryOption(categoryCode: code, name: name, kind: "expense", colorToken: nil, parentCode: nil,
                              archived: false)
}

private let options = [option("cat_dining", "Dining"), option("cat_cafe", "Café"), option("cat_groceries", "Groceries")]

@MainActor
@Suite("Transaction sheet: category, None, merchant default, exclude, notes (IOS-18)")
struct TransactionEditorTests {
    /// An Activity list holding `txn`, so writes re-read and patch it.
    func activity(_ txn: LedgerTransaction) async -> (StubAPI, ActivityModel) {
        let api = StubAPI()
        api.transactionRows["prf_a"] = [txn]
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        return (api, model)
    }

    func editor(_ txn: LedgerTransaction, _ model: ActivityModel) -> TransactionEditor {
        TransactionEditor(transaction: txn, categories: options, profileCode: "prf_a", target: model)
    }

    @Test("the merchant toggle starts on unless the category is this transaction's own manual choice")
    func merchantDefault() {
        #expect(TransactionEditor.defaultsToMerchant(row(category: "cat_a", source: "rule")))
        #expect(TransactionEditor.defaultsToMerchant(row(category: "cat_a", source: "suggested")))
        #expect(TransactionEditor.defaultsToMerchant(row(category: "cat_a", source: "merchant")))
        #expect(TransactionEditor.defaultsToMerchant(row()))                       // uncategorised
        #expect(!TransactionEditor.defaultsToMerchant(row(category: "cat_a", source: "manual")))
        #expect(!TransactionEditor.defaultsToMerchant(row(merchant: nil)))         // no merchant: no toggle
    }

    @Test("None is live only when there is a manual choice to clear")
    func noneClears() {
        #expect(TransactionEditor.canClear(source: "manual", applyToMerchant: false))
        #expect(TransactionEditor.canClear(source: "manual", applyToMerchant: true))
        #expect(TransactionEditor.canClear(source: "merchant", applyToMerchant: true))
        #expect(!TransactionEditor.canClear(source: "merchant", applyToMerchant: false))
        #expect(!TransactionEditor.canClear(source: "rule", applyToMerchant: true))
        #expect(!TransactionEditor.canClear(source: "suggested", applyToMerchant: true))
        #expect(!TransactionEditor.canClear(source: nil, applyToMerchant: true))
    }

    @Test("search matches category names ignoring case and accents; blank shows all")
    func search() {
        #expect(TransactionEditor.filter(options, search: "").count == 3)
        #expect(TransactionEditor.filter(options, search: "  ").count == 3)
        #expect(TransactionEditor.filter(options, search: "din").map(\.categoryCode) == ["cat_dining"])
        #expect(TransactionEditor.filter(options, search: "CAFE").map(\.categoryCode) == ["cat_cafe"])
        #expect(TransactionEditor.filter(options, search: "xyz").isEmpty)
    }

    @Test("searching hides exclude and notes, keeps None only when it matches, and says when nothing does")
    func searchState() async {
        let txn = row(category: "cat_dining", source: "manual")
        let (_, model) = await activity(txn)
        let e = editor(txn, model)
        #expect(e.showsDetails && e.showsNone && e.noMatchMessage == nil)
        e.search = "groc"
        #expect(!e.showsDetails && !e.showsNone && e.visibleCategories.count == 1)
        e.search = "non"
        #expect(e.showsNone && e.noMatchMessage == nil)
        e.search = "xyz "
        #expect(e.noMatchMessage == "No category matches “xyz”.")
    }

    @Test("notes are trimmed, capped at 1000 characters, and blank is no note")
    func notes() {
        #expect(TransactionEditor.normalizedNotes("  Dinner with Sam \n") == "Dinner with Sam")
        #expect(TransactionEditor.normalizedNotes(" \n ") == nil)
        #expect(TransactionEditor.normalizedNotes(String(repeating: "a", count: 1500))?.count == 1000)
    }

    @Test("category source words and the swipe title")
    func labels() {
        #expect(TransactionEditor.sourceLabel("manual") == "Your choice")
        #expect(TransactionEditor.sourceLabel("rule") == "Set by a rule")
        #expect(TransactionEditor.sourceLabel(nil) == nil)
        #expect(TransactionEditor.excludeActionTitle(excluded: false) == "Exclude")
        #expect(TransactionEditor.excludeActionTitle(excluded: true) == "Include")
        #expect(row(category: "cat_a").categoryCaption == "Name cat_a")
        #expect(row(excluded: true).categoryCaption == "Uncategorised · Excluded")
    }

    @Test("the header names where the category came from")
    func header() async {
        let txn = row(category: "cat_dining", source: "merchant")
        let (_, model) = await activity(txn)
        #expect(editor(txn, model).categoryHeader == "Category · Your choice for this merchant")
        let plain = row()
        #expect(editor(plain, model).categoryHeader == "Category")
    }

    @Test("a category saves merchant-wide by default; None clears the transaction's manual choice")
    func chooseCategory() async {
        let ruled = row(category: "cat_dining", source: "rule")
        let (api, model) = await activity(ruled)
        let e = editor(ruled, model)
        #expect(e.applyToMerchant && !e.canChooseNone)
        #expect(await e.choose(nil) == false)                         // nothing manual to clear
        #expect(api.recategorised.isEmpty)
        #expect(await e.choose("cat_groceries"))
        #expect(api.recategorised.last?.category == "cat_groceries" && api.recategorised.last?.merchant == true)

        let manual = row("txn_2", category: "cat_dining", source: "manual")
        let (api2, model2) = await activity(manual)
        let e2 = editor(manual, model2)
        #expect(!e2.applyToMerchant && e2.canChooseNone)
        #expect(await e2.choose(nil))
        #expect(api2.recategorised.last?.txn == "txn_2")
        #expect(api2.recategorised.last?.category == nil && api2.recategorised.last?.merchant == false)
    }

    @Test("no merchant: the toggle is hidden and never applied")
    func noMerchant() async {
        let txn = row(merchant: nil, category: "cat_dining", source: "rule")
        let (api, model) = await activity(txn)
        let e = editor(txn, model)
        e.applyToMerchant = true
        #expect(!e.showsMerchantToggle)
        #expect(await e.choose("cat_cafe"))
        #expect(api.recategorised.last?.merchant == false)
    }

    @Test("a failed save keeps the sheet open with the server's message")
    func failedCategory() async {
        let txn = row(category: "cat_dining", source: "rule")
        let (api, model) = await activity(txn)
        api.transactionWriteError = .server(status: 403, code: "42501", message: "denied")
        let e = editor(txn, model)
        #expect(await e.choose("cat_cafe") == false)
        #expect(e.errorMessage == "You don't have permission to change this ledger (only owners can).")
        #expect(e.busy == nil)
    }

    @Test("exclude saves at once and patches the row; a failure puts the switch back")
    func exclude() async {
        let txn = row()
        let (api, model) = await activity(txn)
        let e = editor(txn, model)
        api.transactionRows["prf_a"] = [row(excluded: true)]          // what the re-read returns
        await e.setExcluded(true)
        #expect(e.excluded)
        #expect(api.transactionEdits.last?.edit == .excludeFromSpend(true))
        #expect(model.rows.first?.excludeFromSpend == true)

        api.transactionWriteError = .network("-1009")
        await e.setExcluded(false)
        #expect(e.excluded && e.errorMessage != nil)
    }

    @Test("notes save trimmed; clearing saves null; unchanged notes don't save")
    func saveNotes() async {
        let txn = row(notes: "old")
        let (api, model) = await activity(txn)
        let e = editor(txn, model)
        #expect(e.notesDraft == "old" && !e.notesChanged)
        await e.saveNotes()
        #expect(api.transactionEdits.isEmpty)
        e.notesDraft = "  Dinner with Sam  "
        #expect(e.notesChanged)
        await e.saveNotes()
        #expect(api.transactionEdits.last?.edit == .notes("Dinner with Sam"))
        #expect(e.notesDraft == "Dinner with Sam" && !e.notesChanged)
        e.notesDraft = "   "
        await e.saveNotes()
        #expect(api.transactionEdits.last?.edit == .notes(nil))
        e.notesDraft = "draft"
        e.discardNotes()
        #expect(e.notesDraft == "")
    }

    @Test("the row's swipe flips exclude_from_spend and patches the row")
    func swipeExclude() async {
        let txn = row(excluded: true)
        let (api, model) = await activity(txn)
        api.transactionRows["prf_a"] = [row(excluded: false)]
        await model.toggleExcluded(txn, profileCode: "prf_a")
        #expect(api.transactionEdits.last?.edit == .excludeFromSpend(false))
        #expect(model.rows.first?.excludeFromSpend == false && model.errorMessage == nil)
        api.transactionWriteError = .network("-1009")
        await model.toggleExcluded(model.rows[0], profileCode: "prf_a")
        #expect(model.errorMessage != nil)
    }
}

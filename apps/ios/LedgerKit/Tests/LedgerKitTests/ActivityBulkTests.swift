import Foundation
import Supabase
import Testing
@testable import LedgerKit

/// PAR-11: Activity bulk select, as the web's bulk bar (WEB-24) does it.
@Suite("Activity bulk: arguments, decoding, wording")
struct ActivityBulkContractTests {
    @Test("ticked rows send p_txn_codes only, sorted and de-duplicated")
    func codesParams() {
        let p = ActivityBulkSelection.ticked(["txn_b", "txn_a", "txn_b"]).params(profileCode: "prf_a")
        #expect(p == ["p_profile_code": .string("prf_a"), "p_txn_codes": .array([.string("txn_a"), .string("txn_b")])])
    }

    @Test("all matching sends p_filter only: the web's filter object, search included")
    func filterParams() {
        var q = ActivityQuery()
        q.search = "  noon "
        q.uncategorizedOnly = true
        q.source = .sms
        q.month = CalendarDay(iso: "2026-09-14")
        let p = ActivityBulkSelection.matching(q).params(profileCode: "prf_a")
        #expect(p["p_txn_codes"] == nil)
        #expect(p["p_filter"] == .object(["from": .string("2026-09-01"), "to": .string("2026-09-30"),
                                          "category": .string("none"), "source": .string("sms"), "q": .string("noon")]))
        // No filters: '{}' is every transaction of the ledger, said explicitly.
        #expect(ActivityBulkSelection.matching(ActivityQuery()).params(profileCode: "prf_a")["p_filter"] == .object([:]))
    }

    @Test("bulk_update_transactions gets the patch keys the server accepts")
    func patchParams() {
        let sel = ActivityBulkSelection.ticked(["txn_a"])
        #expect(sel.bulkUpdateParams(profileCode: "prf_a", patch: .excludeFromSpend(true))["p_patch"]
                == .object(["exclude_from_spend": .bool(true)]))
        #expect(sel.bulkUpdateParams(profileCode: "prf_a", patch: .category("cat_food"))["p_patch"]
                == .object(["manual_category_code": .string("cat_food")]))
    }

    @Test("decodes activity_selection_summary's jsonb (net_aed a decimal string) and the bulk row count")
    func decoding() throws {
        // jsonb_build_object('txn_count', …, 'net_aed', …::numeric(14,2)::text, 'unpriced_count', …,
        //                    'has_estimate', …, 'excluded_count', …)
        let json = Data(#"{"has_estimate": true, "net_aed": "-1234.50", "txn_count": 3, "excluded_count": 3, "unpriced_count": 1}"#.utf8)
        let s = try LedgerJSON.decode(ActivitySelectionSummary.self, from: json)
        #expect(s.txnCount == 3 && s.netAed == Decimal(string: "-1234.50")! && s.unpricedCount == 1)
        #expect(s.hasEstimate && s.excludedCount == 3 && s.allExcluded)
        #expect(try LedgerJSON.decode(Int.self, from: Data("42".utf8)) == 42)   // returns integer
    }

    @Test("wording: counts, net and the web's toasts")
    func wording() {
        #expect(ActivitySelection.countText(.ticked(["a", "b", "c"]), serverCount: nil) == "3 selected")
        #expect(ActivitySelection.countText(.matching(ActivityQuery()), serverCount: nil) == "… selected")
        #expect(ActivitySelection.countText(.matching(ActivityQuery()), serverCount: 1234) == "All 1,234 selected")
        #expect(ActivitySelectionSummary(txnCount: 2, netAed: Decimal(string: "120.5")!).netText == "AED 120.50 net")
        #expect(ActivitySelectionSummary(txnCount: 1, netAed: -20, hasEstimate: true).netText == "+ ≈ AED 20.00 net")
        #expect(ActivityBulkPatch.category("c").doneMessage(changed: 3) == "3 transactions categorised")
        #expect(ActivityBulkPatch.excludeFromSpend(true).doneMessage(changed: 1) == "1 transaction excluded from spending")
        #expect(ActivityBulkPatch.excludeFromSpend(false).doneMessage(changed: 1200) == "1,200 transactions included in spending")
        #expect(ActivityBulkPatch.excludeFromSpend(true).doneMessage(changed: 0) == "Nothing to change")
        #expect(ActivityBulkPatch.category("c").failureTitle == "Couldn't categorise")
        #expect(ActivityBulkPatch.excludeFromSpend(false).failureTitle == "Couldn't include")
    }

    @Test("Include only when every selected row is already excluded")
    func allExcluded() {
        #expect(!ActivitySelectionSummary(txnCount: 0, netAed: 0).allExcluded)
        #expect(!ActivitySelectionSummary(txnCount: 3, netAed: 0, excludedCount: 2).allExcluded)
        #expect(ActivitySelectionSummary(txnCount: 3, netAed: 0, excludedCount: 3).allExcluded)
    }

    @Test("select mode is for owners with rows")
    func offers() {
        #expect(ActivitySelection.offersSelection(canEdit: true, hasRows: true))
        #expect(!ActivitySelection.offersSelection(canEdit: false, hasRows: true))
        #expect(!ActivitySelection.offersSelection(canEdit: true, hasRows: false))
    }
}

@MainActor
@Suite("Activity bulk: selecting and acting")
struct ActivityBulkModelTests {
    func loaded(_ api: StubAPI, rows: Int = 150) async -> ActivityModel {
        api.transactionRows["prf_a"] = txns(0..<rows)
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        return model
    }

    @Test("tick rows, tick all loaded, then all matching; unticking one falls back to the loaded rows")
    func selecting() async {
        let api = StubAPI()
        let model = await loaded(api)
        let sel = model.selection
        let codes = model.loadedCodes
        sel.setSelecting(true)
        #expect(sel.selection(for: model.listedQuery) == nil)
        sel.toggle(codes[0], loaded: codes)
        sel.toggle(codes[1], loaded: codes)
        sel.toggle(codes[0], loaded: codes)
        #expect(sel.selection(for: model.listedQuery) == .codes([codes[1]]))
        #expect(sel.offersSelectAllLoaded(codes))
        #expect(sel.selectAllMatchingTotal(loaded: codes, total: model.total) == nil)

        sel.selectAllLoaded(codes)
        #expect(!sel.offersSelectAllLoaded(codes))
        #expect(sel.selectAllMatchingTotal(loaded: codes, total: model.total) == 150)   // 100 loaded of 150

        sel.selectAllMatching()
        #expect(sel.selection(for: model.listedQuery) == .matching(model.listedQuery))
        #expect(sel.isSelected("not_loaded_yet"))
        #expect(sel.selectAllMatchingTotal(loaded: codes, total: model.total) == nil)

        sel.toggle(codes[5], loaded: codes)
        #expect(!sel.allMatching && sel.ticked.count == 99 && !sel.isSelected(codes[5]))
    }

    @Test("the bar's figures are the server's, for the selection on screen")
    func summary() async {
        let api = StubAPI()
        api.selectionSummaryResult = .success(ActivitySelectionSummary(txnCount: 150, netAed: Decimal(string: "1500.00")!,
                                                                       excludedCount: 150))
        let model = await loaded(api)
        model.selection.setSelecting(true)
        await model.loadSelectionSummary(profileCode: "prf_a")
        #expect(model.selection.summary.value == nil && api.selectionSummaryCalls.isEmpty)   // nothing selected

        model.selection.selectAllMatching()
        await model.loadSelectionSummary(profileCode: "prf_a")
        #expect(api.selectionSummaryCalls.last == .matching(model.listedQuery))
        #expect(model.selection.countText(for: model.listedQuery) == "All 150 selected")
        #expect(model.selection.excludePatch == .excludeFromSpend(false))   // every row excluded: Include
        #expect(model.selection.canExclude)
    }

    @Test("a new filter or ledger drops the selection; a refresh of the same list keeps it")
    func clearsOnNewList() async {
        let api = StubAPI()
        let model = await loaded(api)
        model.selection.setSelecting(true)
        model.selection.toggle(model.loadedCodes[0], loaded: model.loadedCodes)
        await model.load(profileCode: "prf_a")
        #expect(model.selection.ticked.count == 1)
        model.query.status = .pending
        await model.load(profileCode: "prf_a")
        #expect(model.selection.ticked.isEmpty && model.selection.isSelecting)
        model.reset()
        #expect(!model.selection.isSelecting)
    }

    @Test("ticked rows: the write goes out, the rows are re-read in place, the selection clears")
    func applyCodes() async {
        let api = StubAPI()
        api.bulkUpdateResult = .success(2)
        let model = await loaded(api)
        let codes = Array(model.loadedCodes.prefix(2))
        model.selection.setSelecting(true)
        for code in codes { model.selection.toggle(code, loaded: model.loadedCodes) }
        api.transactionRows["prf_a"]![0] = txn(codes[0], category: "cat_food")
        let pages = api.calls("transactions")
        await model.applyBulk(.category("cat_food"), profileCode: "prf_a")
        #expect(api.bulkUpdates.count == 1 && api.bulkUpdates[0].patch == .category("cat_food"))
        #expect(api.bulkUpdates[0].selection == .codes(codes.sorted()))
        #expect(api.calls("transactions") == pages)                 // no page reloaded
        #expect(model.rows[0].categoryCode == "cat_food")           // patched in place
        #expect(model.selection.ticked.isEmpty && model.selection.isSelecting)
        #expect(model.selection.notice == "2 transactions categorised")
    }

    @Test("all matching: the filter goes out and the list reloads")
    func applyMatching() async {
        let api = StubAPI()
        api.bulkUpdateResult = .success(150)
        let model = await loaded(api)
        model.selection.selectAllMatching()
        let pages = api.calls("transactions")
        await model.applyBulk(.excludeFromSpend(true), profileCode: "prf_a")
        #expect(api.bulkUpdates.last?.selection == .matching(model.listedQuery))
        #expect(api.calls("transactions") == pages + 1)
        #expect(model.selection.notice == "150 transactions excluded from spending")
    }

    @Test("a refused write (a viewer, 42501) keeps the selection and says why")
    func applyFails() async {
        let api = StubAPI()
        api.bulkUpdateResult = .failure(.server(status: nil, code: "42501", message: "not an owner"))
        let model = await loaded(api)
        model.selection.toggle(model.loadedCodes[0], loaded: model.loadedCodes)
        await model.applyBulk(.excludeFromSpend(true), profileCode: "prf_a")
        #expect(model.selection.ticked.count == 1 && model.selection.notice == nil)
        #expect(model.selection.failure?.title == "Couldn't exclude")
        #expect(model.selection.failure?.message == "You don't have permission to change this ledger (only owners can).")
    }

    @Test("nothing selected: no write")
    func applyNothing() async {
        let api = StubAPI()
        let model = await loaded(api)
        await model.applyBulk(.excludeFromSpend(true), profileCode: "prf_a")
        #expect(api.bulkUpdates.isEmpty)
    }
}

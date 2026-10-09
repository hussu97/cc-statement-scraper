import Foundation
import Supabase
import Testing
@testable import LedgerKit

@Suite("Insights spending filter: params, options, summary, model")
struct SpendFilterTests {
    static let meta = FilterMeta(
        accounts: [],
        cards: [
            .init(cardCode: "crd_b", accountCode: "acc_1", bankCode: "FAB", last4: "2132", isSupplementary: true),
            .init(cardCode: "crd_a", accountCode: "acc_1", bankCode: "FAB", last4: "2777", isSupplementary: false),
        ],
        categories: [
            .init(categoryCode: "cat_dining", name: "Dining", kind: "spend", colorToken: "cat-1", parentCode: nil, archived: false),
            .init(categoryCode: "cat_groceries", name: "Groceries", kind: "spend", colorToken: "cat-2", parentCode: nil, archived: false),
            .init(categoryCode: "cat_old", name: "Old", kind: "spend", colorToken: nil, parentCode: nil, archived: true),
            .init(categoryCode: "cat_transfer", name: "Transfers", kind: "transfer", colorToken: nil, parentCode: nil, archived: false),
        ],
        banks: [.init(bankCode: "FAB", name: "First Abu Dhabi Bank"), .init(bankCode: "ADCB", name: "ADCB")],
        dateRange: nil)

    @Test("empty: every filter argument is null, and a blank search is no filter")
    func emptyParams() {
        var f = SpendFilter()
        f.search = "   "
        #expect(f.isEmpty && f.activeCount == 0)
        #expect(f.rpcParams == ["p_category_codes": .null, "p_bank_codes": .null, "p_card_codes": .null, "p_q": .null])
        #expect(f.summary(options: nil) == nil)
    }

    @Test("codes go sorted, Uncategorised as its key, the search trimmed but otherwise raw")
    func params() {
        let f = SpendFilter(categoryCodes: ["cat_groceries", SpendFilter.uncategorized, "cat_dining"],
                            bankCodes: ["FAB"], cardCodes: ["crd_a"], search: "  Careem (dxb) 50%  ")
        #expect(!f.isEmpty && f.activeCount == 6)
        #expect(f.rpcParams == [
            "p_category_codes": .array([.string("__uncategorized__"), .string("cat_dining"), .string("cat_groceries")]),
            "p_bank_codes": .array([.string("FAB")]),
            "p_card_codes": .array([.string("crd_a")]),
            "p_q": .string("Careem (dxb) 50%"),
        ])
    }

    @Test("options: spend categories then Uncategorised; banks and cards by code")
    func options() {
        let o = SpendFilterOptions(meta: Self.meta)
        #expect(o.categories.map(\.code) == ["cat_dining", "cat_groceries", "__uncategorized__"])
        #expect(o.categories.last?.label == "Uncategorised")
        #expect(o.banks.map(\.label) == ["ADCB", "FAB"])
        #expect(o.banks.map(\.detail) == [nil, "First Abu Dhabi Bank"])
        #expect(o.cards.map(\.label) == ["•2132", "•2777"])
        #expect(o.cards.map(\.detail) == ["FAB · supplementary", "FAB"])
    }

    @Test("summary: names in the sheet's order, kinds joined by a dot, the search quoted")
    func summary() {
        let o = SpendFilterOptions(meta: Self.meta)
        let f = SpendFilter(categoryCodes: ["cat_groceries", "cat_dining"], bankCodes: ["FAB"], cardCodes: ["crd_a"],
                            search: " careem ")
        #expect(f.summary(options: o) == "Dining, Groceries · FAB · •2777 · “careem”")
        // Before the options load: codes, but Uncategorised still reads as words.
        let early = SpendFilter(categoryCodes: [SpendFilter.uncategorized, "cat_x"])
        #expect(early.summary(options: nil) == "Uncategorised, cat_x")
        var toggled = Set<String>()
        SpendFilter.toggle("a", in: &toggled)
        SpendFilter.toggle("b", in: &toggled)
        SpendFilter.toggle("a", in: &toggled)
        #expect(toggled == ["b"])
    }

    @Test("model: unfiltered None uses the screen's bars; a filter loads spend_series and spend_breakdown with it")
    @MainActor
    func model() async throws {
        let api = StubAPI()
        api.breakdown = try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))
        let model = SpendSplitModel(api: api)
        let from = CalendarDay(iso: "2026-08-01")!, to = CalendarDay(iso: "2026-10-15")!
        await model.load(profileCode: "prf_a", from: from, to: to)
        #expect(api.seriesFilters.isEmpty)
        #expect(model.trend(unfiltered: []).value == [])
        #expect(model.emptyMessage == "No spending in this period.")

        await model.loadOptions(profileCode: "prf_a")
        #expect(model.options?.categories.last?.code == SpendFilter.uncategorized)

        let filter = SpendFilter(bankCodes: ["FAB"])
        model.filter = filter
        await model.load(profileCode: "prf_a", from: from, to: to)
        await model.load(profileCode: "prf_a", from: from, to: to)
        #expect(api.seriesFilters == [filter])
        #expect(model.trend(unfiltered: []).value == [])   // the stub's (filtered) answer, now loaded
        #expect(model.emptyMessage == "No spending matches these filters in this period.")
        #expect(model.filterSummary == "FAB")

        model.grouping = .category
        await model.load(profileCode: "prf_a", from: from, to: to)
        #expect(api.breakdownFilters == [filter])
        model.filter.search = "careem"
        model.selectedMonth = "Oct"
        model.filter.cardCodes = ["crd_a"]
        #expect(model.selectedMonth == nil)
        await model.load(profileCode: "prf_a", from: from, to: to)
        #expect(api.breakdownFilters.last == SpendFilter(bankCodes: ["FAB"], cardCodes: ["crd_a"], search: "careem"))

        // Another ledger: the codes mean nothing there.
        await model.load(profileCode: "prf_b", from: from, to: to)
        #expect(model.filter.isEmpty && model.options == nil)
        #expect(api.breakdownFilters.last == SpendFilter())
    }
}

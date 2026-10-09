import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }

private func status(_ code: String, category: String? = nil, budget: String = "2000", spent: String = "500",
                    projected: String = "1500", share: String = "0.25") -> BudgetStatus {
    BudgetStatus(budgetCode: code, categoryCode: category, categoryName: category == nil ? "All spending" : "Groceries",
                 colorToken: category == nil ? nil : "cat-2", budgetAed: dec(budget), spentAed: dec(spent),
                 projectedAed: dec(projected), shareUsed: dec(share))
}

private func budget(_ code: String, category: String? = nil, amount: String = "2000", from: String = "2026-09-01",
                    to: String? = nil) -> Budget {
    Budget(budgetCode: code, categoryCode: category, amountAed: dec(amount), effectiveFrom: day(from),
           effectiveTo: to.map(day))
}

private func category(_ code: String, kind: String = "spend", parent: String? = nil, archived: Bool = false) -> FilterMeta.CategoryOption {
    FilterMeta.CategoryOption(categoryCode: code, name: "Name \(code)", kind: kind, colorToken: nil, parentCode: parent,
                              archived: archived)
}

@Suite("Budgets: tone, labels and phases (web parity)")
struct BudgetPresentationTests {
    @Test("tone: over is danger, 80% used is a warning, overspend pace warns only in the current month")
    func tone() {
        #expect(status("b", share: "1.01").tone(isCurrentMonth: false) == .danger)
        #expect(status("b", share: "0.8").tone(isCurrentMonth: false) == .warn)
        #expect(status("b", projected: "2500", share: "0.5").tone(isCurrentMonth: true) == .warn)
        #expect(status("b", projected: "2500", share: "0.5").tone(isCurrentMonth: false) == .positive)
        #expect(status("b", share: "0.25").tone(isCurrentMonth: true) == .positive)
    }

    @Test("labels render the server's figures: used share, pace and the meter's VoiceOver")
    func labels() {
        let row = status("b", category: "cat_g", budget: "2000", spent: "1200.40", projected: "2480.55", share: "0.6002")
        #expect(row.usedLabel == "60% used")
        #expect(row.progressLabel == "AED 1,200 of AED 2,000")
        #expect(row.paceLabel(.current) == "On pace for AED 2,481")
        #expect(row.paceLabel(.past) == "Month closed")
        #expect(row.paceLabel(.future) == "Month not started")
        #expect(row.isOverPace(.current) && !row.isOverPace(.past))
        #expect(row.meterAccessibilityLabel == "60% of Groceries budget used")
        #expect(status("b", share: "1.4").progressFraction == 1)
    }

    @Test("month phase compares calendar months in Dubai")
    func phase() {
        let today = day("2026-10-09")
        #expect(BudgetMonthPhase(month: day("2026-09-01"), today: today) == .past)
        #expect(BudgetMonthPhase(month: day("2026-10-01"), today: today) == .current)
        #expect(BudgetMonthPhase(month: day("2026-11-01"), today: today) == .future)
    }

    @Test("why a budget isn't active in a month")
    func inactiveLabel() {
        let oct = day("2026-10-01")
        #expect(budget("b", from: "2026-11-01").inactiveLabel(month: oct) == "Starts November 2026")
        #expect(budget("b", from: "2026-01-01", to: "2026-08-01").inactiveLabel(month: oct) == "Ended August 2026")
        #expect(budget("b", from: "2026-01-01").inactiveLabel(month: oct) == "Replaced by a newer budget")
        #expect(budget("b", from: "2026-10-01", to: "2026-10-01").applies(to: day("2026-10-31")))
    }
}

@Suite("Budgets: the form (validateBudget parity)")
struct BudgetDraftTests {
    @Test("amount: digits with up to two decimals, above zero; commas are dropped")
    func amount() {
        var d = BudgetDraft(effectiveFrom: day("2026-10-01"))
        for bad in ["", "0", "0.00", "-5", "12.345", "1e3", "abc", "5O", ".5", "5."] {
            d.amount = bad
            #expect(d.validate() == "Enter an amount above zero, e.g. 1500 or 1500.50.", "\(bad)")
        }
        for good in ["1500", "1500.5", "1,500.50", " 20 "] {
            d.amount = good
            #expect(d.validate() == nil, "\(good)")
        }
        d.amount = "1,500.50"
        #expect(d.normalizedAmount == "1500.50")
    }

    @Test("months: starts on a first, ends on or after the start")
    func months() {
        var d = BudgetDraft(amount: "100", effectiveFrom: day("2026-10-02"))
        #expect(d.validate() == "A budget starts on the first of a month.")
        d = BudgetDraft(amount: "100", effectiveFrom: day("2026-10-01"), effectiveTo: day("2026-09-01"))
        #expect(d.validate() == "The end month must be after the start month.")
        d.effectiveTo = day("2026-10-01")
        #expect(d.validate() == nil)
        d.setStart(day("2026-12-01"))
        #expect(d.effectiveTo == nil && d.effectiveFrom == day("2026-12-01"))
    }

    @Test("a new budget starts in the month on screen, or this month when that one is past")
    func newDraft() {
        let today = day("2026-10-09")
        #expect(BudgetDraft.new(month: day("2026-07-01"), today: today).effectiveFrom == day("2026-10-01"))
        #expect(BudgetDraft.new(month: day("2026-10-01"), today: today).effectiveFrom == day("2026-10-01"))
        let d = BudgetDraft.new(month: day("2026-10-01"), today: today)
        #expect(d.isNew && d.title == "New budget" && d.saveLabel == "Create budget" && d.categoryCode == nil)
    }

    @Test("editing keeps the stored amount exactly, as plain digits")
    func edit() {
        let d = BudgetDraft(budget: budget("bud_1", category: "cat_g", amount: "1234567.89", to: "2027-01-01"))
        #expect(d.amount == "1234567.89" && d.budgetCode == "bud_1" && d.title == "Edit budget")
        #expect(d.saveLabel == "Save changes" && d.effectiveTo == day("2027-01-01"))
        #expect(d.savedMessage == "Budget updated. Applies from September 2026.")
    }

    @Test("month pickers: two years around today, ends never before the start")
    func choices() {
        let today = day("2026-10-09")
        let d = BudgetDraft(amount: "1", effectiveFrom: day("2026-10-01"))
        let starts = d.startChoices(today: today)
        #expect(starts.first == day("2024-10-01") && starts.last == day("2028-10-01") && starts.count == 49)
        let ends = d.endChoices(today: today)
        #expect(ends.first == day("2026-10-01") && ends.last == day("2028-10-01"))
        let old = BudgetDraft(amount: "1", effectiveFrom: day("2020-01-01"))
        #expect(old.startChoices(today: today).first == day("2020-01-01"))
    }

    @Test("categories: spend and fee only, archived hidden unless it is the budget's own, children under parents")
    func categories() {
        let options = [
            category("food"), category("salary", kind: "income"), category("old", archived: true),
            category("bank_fee", kind: "fee"), category("groceries", parent: "food"), category("move", kind: "transfer"),
        ]
        let codes = BudgetCategoryChoice.choices(from: options, keeping: nil).map(\.categoryCode)
        #expect(codes == ["food", "groceries", "bank_fee"])
        let kept = BudgetCategoryChoice.choices(from: options, keeping: "old")
        #expect(kept.map(\.categoryCode) == ["food", "groceries", "old", "bank_fee"])
        #expect(kept.first { $0.categoryCode == "groceries" }?.depth == 1)
    }
}

@MainActor
@Suite("Budgets tab: load, write, refresh")
struct BudgetsModelTests {
    @Test("loads the month's status, every budget and the categories; inactive budgets listed apart")
    func load() async throws {
        let api = StubAPI()
        api.budgetStatusRows = [status("bud_total")]
        api.budgetRows = [budget("bud_future", category: "food", from: "2026-12-01"), budget("bud_total")]
        api.categoryOptions = [category("food")]
        let model = BudgetsModel(api: api)
        await model.load(profileCode: "prf_a", month: day("2026-09-01"))
        let content = try #require(model.state.value)
        #expect(api.budgetMonths == [day("2026-09-01")])
        #expect(content.inactive.map(\.budgetCode) == ["bud_future"])
        #expect(content.name(of: content.inactive[0]) == "Name food")
        #expect(content.name(of: budget("x")) == "All spending")
        #expect(content.draft(for: "bud_total")?.amount == "2000")
        #expect(!content.categoriesFailed)
    }

    @Test("empty: 'No budgets yet' only when the ledger has none at all")
    func empty() async throws {
        let api = StubAPI()
        let model = BudgetsModel(api: api)
        await model.load(profileCode: "prf_a", month: nil)
        var content = try #require(model.state.value)
        #expect(content.emptyTitle(month: day("2026-10-01")) == "No budgets yet")
        api.budgetRows = [budget("bud_x", from: "2026-12-01")]
        await model.load(profileCode: "prf_a", month: nil)
        content = try #require(model.state.value)
        #expect(content.emptyTitle(month: day("2026-10-01")) == "No budgets apply to October 2026")
    }

    @Test("categories failing doesn't fail the tab")
    func categoriesFail() async throws {
        let api = StubAPI()
        api.filterMetaError = .network("offline")
        let model = BudgetsModel(api: api)
        await model.load(profileCode: "prf_a", month: nil)
        #expect(try #require(model.state.value).categoriesFailed)
    }

    @Test("save validates first, sends the draft, reloads and tells Insights")
    func save() async {
        let api = StubAPI()
        let model = BudgetsModel(api: api)
        var told: [String] = []
        model.onChange = { told.append($0) }
        await model.load(profileCode: "prf_a", month: nil)
        var draft = BudgetDraft(effectiveFrom: day("2026-10-01"))
        #expect(await model.save(draft, profileCode: "prf_a") == "Enter an amount above zero, e.g. 1500 or 1500.50.")
        #expect(api.savedBudgets.isEmpty)
        draft.amount = "1,500.50"
        #expect(await model.save(draft, profileCode: "prf_a") == nil)
        #expect(api.savedBudgets.map(\.draft.normalizedAmount) == ["1500.50"])
        #expect(api.calls("budgetStatus") == 2 && told == ["prf_a"])
        #expect(model.notice?.text == "Budget created. Applies from October 2026.")
    }

    @Test("a duplicate start month and a viewer's write get readable errors")
    func saveErrors() async {
        let api = StubAPI()
        let model = BudgetsModel(api: api)
        let draft = BudgetDraft(amount: "100", effectiveFrom: day("2026-10-01"))
        api.budgetWriteError = .server(status: nil, code: "23505", message: "duplicate key")
        #expect(await model.save(draft, profileCode: "prf_a")
                == "There is already a budget for this category starting that month. Edit that one instead.")
        api.budgetWriteError = .server(status: nil, code: "42501", message: "rls")
        #expect(await model.save(draft, profileCode: "prf_a")
                == "You don't have permission to change this ledger (only owners can).")
    }

    @Test("delete sends the code and reloads; a failure is a notice, not a crash")
    func delete() async {
        let api = StubAPI()
        let model = BudgetsModel(api: api)
        await model.load(profileCode: "prf_a", month: nil)
        await model.delete(budgetCode: "bud_1", profileCode: "prf_a")
        #expect(api.deletedBudgets == ["bud_1"] && model.notice == .init(text: "Budget deleted.", isError: false))
        api.budgetWriteError = .network("offline")
        await model.delete(budgetCode: "bud_2", profileCode: "prf_a")
        #expect(model.notice?.isError == true)
        #expect(BudgetsModel.deleteMessage(name: "Groceries")
                == "The Groceries budget goes away for every month it covered. Your transactions aren't affected.")
    }

    @Test("a transactions change refreshes an opened Budgets tab; switching ledger clears it")
    func screens() async {
        let api = StubAPI()
        let screens = LedgerScreens(api: api, today: { day("2026-10-09") })
        await screens.select("prf_a")
        #expect(api.calls("budgetStatus") == 0)   // not opened: not loaded
        await screens.budgets.load(profileCode: "prf_a", month: nil)
        await screens.refresh(after: ["transactions"])
        #expect(api.calls("budgetStatus") == 2)
        await screens.select("prf_b")
        #expect(!screens.budgets.hasLoaded)
        screens.stop()
    }
}

@MainActor
@Suite("Tabs: Budgets replaces Statements")
struct LedgerTabTests {
    @Test("the tab bar is Overview, Activity, Insights, Budgets, Settings")
    func order() {
        #expect(LedgerTab.allCases.map(\.title) == ["Overview", "Activity", "Insights", "Budgets", "Settings"])
    }

    @Test("See all switches tabs; a new ledger starts on Overview")
    func router() {
        let router = TabRouter()
        router.show(.budgets)
        #expect(router.tab == .budgets)
        router.reset()
        #expect(router.tab == .overview)
    }

    @Test("the share sheet points at Settings → Statements")
    func shareMessage() {
        #expect(ShareOutcome.uploaded(queued: 1, duplicates: 0).message
                == "Sent: watch progress in Bank Ledger → Settings → Statements.")
    }
}

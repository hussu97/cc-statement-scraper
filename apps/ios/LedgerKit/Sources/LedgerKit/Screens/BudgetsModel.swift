import Foundation
import Observation

/// Budgets tab: every budget of the ledger as `budget_status` reports it for
/// the month (`p_include_inactive`), split on the server's `is_effective`
/// (CLAUDE.md §2.2: the device never works out which budget applies), and
/// create / edit / delete on `public.budgets` for owners. Parity with the web
/// Budgets page.
@MainActor
@Observable
public final class BudgetsModel {
    public struct Content: Sendable {
        /// `budget_status` for the month in the server's order: the budgets
        /// that count (total first), then the ledger's others.
        public let rows: [BudgetStatus]
        /// `filter_meta.categories`; empty when they couldn't load.
        public let categories: [FilterMeta.CategoryOption]
        /// Categories failed to load: the form can still budget all spending.
        public let categoriesFailed: Bool
        /// `public.accounts` (active and closed); empty when they couldn't load.
        public let accounts: [LedgerAccount]
        /// Cards failed to load: the form can still budget every card.
        public let accountsFailed: Bool

        public init(rows: [BudgetStatus], categories: [FilterMeta.CategoryOption],
                    categoriesFailed: Bool = false, accounts: [LedgerAccount] = [], accountsFailed: Bool = false) {
            self.rows = rows
            self.categories = categories
            self.categoriesFailed = categoriesFailed
            self.accounts = accounts
            self.accountsFailed = accountsFailed
        }
    }

    public struct Notice: Equatable, Sendable {
        public let text: String
        public let isError: Bool
    }

    public private(set) var state: LoadState<Content> = .idle
    public private(set) var isSaving = false
    /// The budget being deleted, while the request runs.
    public private(set) var deleting: String?
    /// The last write's outcome (`"Budget created. Applies from …"` or an error).
    public var notice: Notice?
    /// Runs after a successful write, with the ledger: Insights' budgets card reloads.
    public var onChange: (@MainActor (String) async -> Void)?

    private let api: any LedgerAPI
    private var gate = RequestGate<Key>()

    struct Key: Hashable, Sendable {
        let profileCode: String
        let month: CalendarDay?
    }

    public init(api: any LedgerAPI) { self.api = api }

    public var hasLoaded: Bool { gate.requested != nil }

    /// `month`: what `MonthSelection.requestMonth` says (nil: the current month).
    public func load(profileCode: String, month: CalendarDay?) async {
        let key = Key(profileCode: profileCode, month: month)
        let (ticket, sameKey) = gate.begin(key)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        let api = self.api
        do {
            async let status = api.budgetStatus(profileCode: profileCode, month: month, includeInactive: true)
            async let meta: FilterMeta? = try? api.filterMeta(profileCode: profileCode)
            async let accounts: [LedgerAccount]? = try? api.accounts(profileCode: profileCode)
            let (s, m, a) = try await (status, meta, accounts)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(key)
            state = .loaded(Content(rows: s, categories: m?.categories ?? [], categoriesFailed: m == nil,
                                    accounts: a ?? [], accountsFailed: a == nil))
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    /// Loads unless this ledger and month are already on screen or loading.
    public func loadIfNeeded(profileCode: String, month: CalendarDay?) async {
        let key = Key(profileCode: profileCode, month: month)
        guard gate.requested != key || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode, month: month)
    }

    /// Reloads what is on screen (foreground, Realtime, after a write), if anything is.
    public func refresh(profileCode: String) async {
        guard let requested = gate.requested, requested.profileCode == profileCode else { return }
        await load(profileCode: profileCode, month: requested.month)
    }

    public func reset() {
        gate.reset()
        state = .idle
        notice = nil
        isSaving = false
        deleting = nil
    }

    // MARK: Writes

    /// Validates and saves. Returns nil when saved (the sheet closes), or the
    /// sentence the form shows.
    public func save(_ draft: BudgetDraft, profileCode: String) async -> String? {
        if let problem = draft.validate() { return problem }
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.saveBudget(profileCode: profileCode, draft: draft)
        } catch {
            return Self.writeError(error)
        }
        notice = Notice(text: draft.savedMessage, isError: false)
        await afterWrite(profileCode)
        return nil
    }

    public func delete(budgetCode: String, profileCode: String) async {
        guard deleting == nil else { return }
        deleting = budgetCode
        defer { deleting = nil }
        do {
            try await api.deleteBudget(budgetCode: budgetCode)
            notice = Notice(text: "Budget deleted.", isError: false)
            await afterWrite(profileCode)
        } catch {
            notice = Notice(text: "Couldn't delete the budget. \(Self.writeError(error))", isError: true)
        }
    }

    private func afterWrite(_ profileCode: String) async {
        await refresh(profileCode: profileCode)
        await onChange?(profileCode)
    }

    /// `23505` is the one-budget-per-scope-and-start-month index (`budgets_uq`: card × category).
    nonisolated static func writeError(_ error: any Error) -> String {
        if case LedgerAPIError.server(_, "23505", _)? = error as? LedgerAPIError {
            return "There is already a budget for this card and category starting that month. Edit that one instead."
        }
        return LoadState<Content>.message(for: error)
    }
}

extension BudgetsModel.Content {
    /// The budgets that count for the month (the server's `is_effective`), total first.
    public var status: [BudgetStatus] { rows.filter(\.isEffective) }

    /// The ledger's other budgets (upcoming, ended, replaced), in the server's order.
    public var inactive: [BudgetStatus] { rows.filter { !$0.isEffective } }

    /// The ledger has no budgets at all (not just none this month).
    public var hasNoBudgets: Bool { rows.isEmpty }

    /// The edit form for a budget on screen.
    public func draft(for budgetCode: String) -> BudgetDraft? {
        rows.first { $0.budgetCode == budgetCode }.flatMap(BudgetDraft.init(status:))
    }

    /// The form's card list (see `BudgetCardChoice`); `"All cards"` comes before it.
    public func cardChoices(keeping current: String?) -> [BudgetCardChoice] {
        BudgetCardChoice.choices(from: accounts, keeping: current)
    }

    /// The form's category list (see `BudgetCategoryChoice`).
    public func categoryChoices(keeping current: String?) -> [BudgetCategoryChoice] {
        BudgetCategoryChoice.choices(from: categories, keeping: current)
    }

    /// The empty state when the month has no budget rows.
    public func emptyTitle(month: CalendarDay) -> String {
        hasNoBudgets ? "No budgets yet" : "No budgets apply to \(LedgerDates.monthTitle(month))"
    }

    public var emptyDetail: String {
        hasNoBudgets
            ? "Set a monthly limit for all spending or for a category, on every card or just one, and Bank Ledger will track it as the month goes."
            : "Your budgets start later or ended earlier. They're listed below."
    }
}

extension BudgetsModel {
    /// The delete confirmation: `"The Groceries budget goes away for every month it covered. …"`.
    public nonisolated static func deleteMessage(name: String) -> String {
        "The \(name) budget goes away for every month it covered. Your transactions aren't affected."
    }
}

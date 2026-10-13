import Foundation
import Observation

/// Activity tab: `v_transactions`, newest first, with search and filters,
/// scrolling page after page (`Paginator`).
@MainActor
@Observable
public final class ActivityModel: TransactionEditing {
    public struct DaySection: Identifiable, Sendable, Hashable {
        public var id: CalendarDay { day }
        public let day: CalendarDay
        public let title: String
        public let rows: [LedgerTransaction]
    }

    /// The filters on screen. Search text binds here directly (debounced by
    /// the view); the filter sheet edits a copy and hands it to `apply`, so a
    /// sheet swiped away changes nothing.
    public var query = ActivityQuery()
    public let list = Paginator<LedgerTransaction>()
    public private(set) var meta: FilterMeta?
    /// `activity_summary` for the rows listed. Its failure only hides the header.
    public private(set) var summary: LoadState<ActivitySummary> = .idle
    /// The date headers' net totals (`activity_day_totals`), one call per page.
    public let dayTotals: ActivityDayTotals
    /// Bulk select (PAR-11): owners tick rows, then Categorise or Exclude / Include them.
    public let selection: ActivitySelection
    public var errorMessage: String?

    private let api: any LedgerAPI
    /// The ledger and filters the rows on screen were loaded for.
    private var loadedFor: (profileCode: String, query: ActivityQuery)?
    /// Drops summaries a newer search or filter superseded.
    private var summaryGate = RequestGate<SummaryKey>()
    private struct SummaryKey: Hashable, Sendable {
        let profileCode: String
        let query: ActivityQuery
    }

    /// `sections` for the rows at `revision`, labelled relative to `today`.
    @ObservationIgnored private var sectionsCache: (revision: Int, today: CalendarDay, sections: [DaySection])?
    /// How many times the sections were built (tests check the cache).
    @ObservationIgnored private(set) var sectionBuilds = 0

    public init(api: any LedgerAPI) {
        self.api = api
        dayTotals = ActivityDayTotals(api: api)
        selection = ActivitySelection(api: api)
    }

    public var state: LoadState<[LedgerTransaction]> { list.state }
    public var rows: [LedgerTransaction] { list.items }
    public var total: Int? { list.total }
    public var footer: ListFooter { list.footer }
    /// The rows by day. Built when the rows (or the day) change, not on every
    /// body evaluation: after a few "Load more" pages that is thousands of rows
    /// grouped and sorted per keystroke (IOS-26).
    public var sections: [DaySection] { sections(today: LedgerDates.today()) }
    public var hasLoaded: Bool { loadedFor != nil }
    /// The filters the rows on screen were loaded with (the search box may hold newer text).
    public var listedQuery: ActivityQuery { loadedFor?.query ?? query }
    public var summaryDisplay: ActivitySummaryDisplay { .of(summary) }

    /// A failed load with nothing cached shows the error; an empty result shows
    /// "no transactions" only when the server said so.
    public var emptyMessage: String? {
        guard case .loaded(let rows) = state, rows.isEmpty else { return nil }
        return query.searchOrFilter != nil || query.hasFilters
            ? "No transactions match these filters."
            : "No transactions yet. They appear here as SMS and statements arrive."
    }

    /// `"All 1,234 transactions"` under the last row.
    public var endMessage: String {
        ListEnd.message(count: rows.count, total: total, singular: "transaction", plural: "transactions")
    }

    /// Page 1 for the current filters. The same ledger and filters keep their
    /// rows on screen while refreshing (pull-to-refresh, or typing a search);
    /// new filters or a new ledger never show the old rows under them.
    public func load(profileCode: String) async {
        let query = self.query
        let same = loadedFor.map { Self.keepsRows(from: $0, to: (profileCode, query)) } ?? false
        // Another ledger, filter or search is another list: its selection starts empty (as on the web).
        if loadedFor.map({ $0.profileCode != profileCode || $0.query != query }) ?? false { selection.clear() }
        loadedFor = (profileCode, query)
        let api = self.api
        async let metaLoad: Void = loadMetaIfNeeded(profileCode: profileCode)
        async let summaryLoad: Void = loadSummary(profileCode: profileCode, query: query)
        await list.reload(keepingRows: same) { page in
            let result = try await api.transactions(profileCode: profileCode, query: query, page: page)
            return ListPage(items: result.rows, total: result.total)
        }
        if loadedFor?.profileCode == profileCode, loadedFor?.query == query {
            await dayTotals.load(days: rows.map(\.txnDate), profileCode: profileCode, query: query, refresh: true)
        }
        await metaLoad
        await summaryLoad
    }

    /// A date header's figure, once the server has said.
    public func dayTotal(for day: CalendarDay) -> DayTotal? { dayTotals.byDay[day] }

    /// Loads unless these filters of this ledger are already on screen
    /// (the tab re-appearing, the search debounce firing with nothing typed).
    public func loadIfNeeded(profileCode: String) async {
        if let loadedFor, loadedFor.profileCode == profileCode, loadedFor.query == query, list.hasLoaded || list.state.isLoading {
            return
        }
        await load(profileCode: profileCode)
    }

    /// Applies the filter sheet's copy (keeping the live search text).
    public func apply(_ draft: ActivityQuery, profileCode: String) async {
        var next = draft
        next.search = query.search
        query = next
        await load(profileCode: profileCode)
    }

    /// Shows exactly `query`, search included: another screen opened Activity with it.
    public func show(_ query: ActivityQuery, profileCode: String) async {
        self.query = query
        await load(profileCode: profileCode)
    }

    /// Realtime / foreground: refresh the newest page, keep the scrolled pages.
    public func refresh(profileCode: String) async {
        guard let loadedFor, loadedFor.profileCode == profileCode else { return }
        async let summaryLoad: Void = loadSummary(profileCode: profileCode, query: loadedFor.query)
        await list.refreshHead()
        await dayTotals.load(days: rows.prefix(list.pageSize).map(\.txnDate), profileCode: profileCode,
                             query: loadedFor.query, refresh: true)
        await summaryLoad
    }

    public func rowAppeared(_ txn: LedgerTransaction) async {
        await list.rowAppeared(txn.id)
        await loadNewDayTotals()
    }
    public func footerAppeared() async {
        await list.footerAppeared()
        await loadNewDayTotals()
    }
    public func loadMore() async {
        await list.loadMore()
        await loadNewDayTotals()
    }

    /// The days of a page just added (days already asked for are skipped).
    private func loadNewDayTotals() async {
        guard let loadedFor else { return }
        await dayTotals.load(days: rows.map(\.txnDate), profileCode: loadedFor.profileCode, query: loadedFor.query)
    }

    public func clearFilters() { query.clearFilters() }

    /// One transaction of the ledger, for a sheet opened from another screen;
    /// nil (and `errorMessage`) when it is gone or the read failed.
    public func transaction(_ txnCode: String, profileCode: String) async -> LedgerTransaction? {
        do {
            if let txn = try await api.transactions(profileCode: profileCode, codes: [txnCode]).first { return txn }
            errorMessage = "This transaction is no longer in this ledger."
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
        }
        return nil
    }

    /// The details sheet of a listed transaction (everyone; owners also edit).
    public func detail(for txn: LedgerTransaction, profileCode: String) -> TransactionDetailModel {
        TransactionDetailModel(transaction: txn, profileCode: profileCode, api: api)
    }

    /// Another ledger or sign-out.
    public func reset() {
        list.reset()
        loadedFor = nil
        meta = nil
        summary = .idle
        summaryGate.reset()
        dayTotals.reset()
        query = ActivityQuery()
        selection.setSelecting(false)
        errorMessage = nil
    }

    /// Recategorise one transaction (nil clears the manual choice), optionally
    /// every transaction from its merchant, then re-read the affected rows and
    /// patch them where they are (the list keeps its scroll position and pages).
    /// A row that no longer matches the category filter leaves the list.
    public func saveCategory(_ txn: LedgerTransaction, to categoryCode: String?, applyToMerchant: Bool,
                             profileCode: String) async throws {
        let wholeMerchant = applyToMerchant && txn.merchantCode != nil
        try await api.setTransactionCategory(txnCode: txn.txnCode, categoryCode: categoryCode,
                                             applyToMerchant: wholeMerchant)
        await reread(Self.affectedCodes(of: txn, wholeMerchant: wholeMerchant, in: rows), profileCode: profileCode)
    }

    /// Saves a note or the exclude flag, then patches the row in place.
    public func saveEdit(_ txn: LedgerTransaction, _ edit: TransactionEdit, profileCode: String) async throws {
        try await api.updateTransaction(txnCode: txn.txnCode, edit: edit)
        await reread([txn.txnCode], profileCode: profileCode)
    }

    /// The row's swipe action: flips `exclude_from_spend`. A failure shows in
    /// `errorMessage` (no sheet is open to show it).
    public func toggleExcluded(_ txn: LedgerTransaction, profileCode: String) async {
        do {
            try await saveEdit(txn, .excludeFromSpend(!txn.excludeFromSpend), profileCode: profileCode)
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
        }
    }

    /// After a write: re-read these rows, patch them, drop the ones the
    /// filters no longer keep, and refresh the summary.
    func reread(_ codes: [String], profileCode: String) async {
        // The rows' days, before a row that left the filter is dropped: their totals change.
        let days = rows.filter { codes.contains($0.txnCode) }.map(\.txnDate)
        do {
            let updated = try await api.transactions(profileCode: profileCode, codes: codes)
            list.patch(updated)
            let gone = updated.filter { !query.keeps(categoryCode: $0.categoryCode) }.map(\.id)
            list.remove(Set(gone))
        } catch {
            // Saved, but the re-read failed: refresh the head rather than show stale rows.
            await list.refreshHead()
        }
        guard let loadedFor else { return }
        await dayTotals.load(days: days, profileCode: loadedFor.profileCode, query: loadedFor.query, refresh: true)
        await loadSummary(profileCode: loadedFor.profileCode, query: loadedFor.query)
    }

    private func loadMetaIfNeeded(profileCode: String) async {
        guard meta == nil else { return }
        let fetched = try? await api.filterMeta(profileCode: profileCode)
        if loadedFor?.profileCode == profileCode { meta = fetched }
    }

    /// The same ledger and filters keep their figures while refreshing; new
    /// filters show the placeholder rather than the old figures under them.
    private func loadSummary(profileCode: String, query: ActivityQuery) async {
        let key = SummaryKey(profileCode: profileCode, query: query)
        let (ticket, same) = summaryGate.begin(key)
        summary = .loading(previous: same ? summary.value : nil)
        let api = self.api
        do {
            let fetched = try await api.activitySummary(profileCode: profileCode, query: query)
            guard summaryGate.isCurrent(ticket) else { return }
            summary = .loaded(fetched)
            summaryGate.finish(key)
        } catch {
            guard summaryGate.isCurrent(ticket) else { return }
            summary = .failed(LoadState<ActivitySummary>.message(for: error), previous: nil)
        }
    }

    func sections(today: CalendarDay) -> [DaySection] {
        let revision = list.revision
        if let cache = sectionsCache, cache.revision == revision, cache.today == today { return cache.sections }
        let built = Self.sections(rows, today: today)
        sectionsCache = (revision, today, built)
        sectionBuilds += 1
        return built
    }

    // MARK: Pure

    /// Rows stay on screen while reloading only for the same ledger and the
    /// same filters (the search text may differ).
    nonisolated static func keepsRows(from old: (profileCode: String, query: ActivityQuery),
                                      to new: (profileCode: String, query: ActivityQuery)) -> Bool {
        var a = old.query, b = new.query
        a.search = ""
        b.search = ""
        return old.profileCode == new.profileCode && a == b
    }

    /// The loaded rows a recategorise touches: the row, plus (for the whole
    /// merchant) every loaded row from that merchant.
    nonisolated static func affectedCodes(of txn: LedgerTransaction, wholeMerchant: Bool,
                                          in rows: [LedgerTransaction]) -> [String] {
        guard wholeMerchant, let merchant = txn.merchantCode else { return [txn.txnCode] }
        var codes = [txn.txnCode]
        codes += rows.filter { $0.merchantCode == merchant && $0.txnCode != txn.txnCode }.map(\.txnCode)
        return codes
    }

    /// Rows grouped by business date, newest first, keeping server order within a day.
    public nonisolated static func sections(_ rows: [LedgerTransaction], today: CalendarDay = LedgerDates.today()) -> [DaySection] {
        var order: [CalendarDay] = []
        var grouped: [CalendarDay: [LedgerTransaction]] = [:]
        for row in rows {
            if grouped[row.txnDate] == nil { order.append(row.txnDate) }
            grouped[row.txnDate, default: []].append(row)
        }
        return order.sorted(by: >).map {
            DaySection(day: $0, title: LedgerDates.relativeDayLabel($0, today: today), rows: grouped[$0]!)
        }
    }
}

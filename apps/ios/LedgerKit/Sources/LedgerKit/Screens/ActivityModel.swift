import Foundation
import Observation

/// Activity tab: `v_transactions`, newest first, with search and filters,
/// scrolling page after page (`Paginator`).
@MainActor
@Observable
public final class ActivityModel {
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
    public var errorMessage: String?

    private let api: any LedgerAPI
    /// The ledger and filters the rows on screen were loaded for.
    private var loadedFor: (profileCode: String, query: ActivityQuery)?

    public init(api: any LedgerAPI) { self.api = api }

    public var state: LoadState<[LedgerTransaction]> { list.state }
    public var rows: [LedgerTransaction] { list.items }
    public var total: Int? { list.total }
    public var footer: ListFooter { list.footer }
    public var sections: [DaySection] { Self.sections(rows) }
    public var hasLoaded: Bool { loadedFor != nil }

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
        loadedFor = (profileCode, query)
        let api = self.api
        async let metaLoad: Void = loadMetaIfNeeded(profileCode: profileCode)
        await list.reload(keepingRows: same) { page in
            let result = try await api.transactions(profileCode: profileCode, query: query, page: page)
            return ListPage(items: result.rows, total: result.total)
        }
        await metaLoad
    }

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

    /// Realtime / foreground: refresh the newest page, keep the scrolled pages.
    public func refresh(profileCode: String) async {
        guard let loadedFor, loadedFor.profileCode == profileCode else { return }
        await list.refreshHead()
    }

    public func rowAppeared(_ txn: LedgerTransaction) async { await list.rowAppeared(txn.id) }
    public func footerAppeared() async { await list.footerAppeared() }
    public func loadMore() async { await list.loadMore() }

    public func clearFilters() { query.clearFilters() }

    /// Another ledger or sign-out.
    public func reset() {
        list.reset()
        loadedFor = nil
        meta = nil
        query = ActivityQuery()
        errorMessage = nil
    }

    /// Recategorise one transaction, optionally every transaction from its
    /// merchant, then re-read the affected rows and patch them where they are
    /// (the list keeps its scroll position and pages). A row that no longer
    /// matches the category filter leaves the list.
    public func setCategory(_ txn: LedgerTransaction, to categoryCode: String, applyToMerchant: Bool,
                            profileCode: String) async -> Bool {
        let wholeMerchant = applyToMerchant && txn.merchantCode != nil
        do {
            try await api.setTransactionCategory(txnCode: txn.txnCode, categoryCode: categoryCode,
                                                 applyToMerchant: wholeMerchant)
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
            return false
        }
        let codes = Self.affectedCodes(of: txn, wholeMerchant: wholeMerchant, in: rows)
        do {
            let updated = try await api.transactions(profileCode: profileCode, codes: codes)
            list.patch(updated)
            let gone = updated.filter { !query.keeps(categoryCode: $0.categoryCode) }.map(\.id)
            list.remove(Set(gone))
        } catch {
            // Saved, but the re-read failed: refresh the head rather than show stale rows.
            await list.refreshHead()
        }
        return true
    }

    private func loadMetaIfNeeded(profileCode: String) async {
        guard meta == nil else { return }
        let fetched = try? await api.filterMeta(profileCode: profileCode)
        if loadedFor?.profileCode == profileCode { meta = fetched }
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

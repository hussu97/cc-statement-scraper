import Foundation
import Observation

/// Activity tab: `v_transactions`, newest first, with search, filters and paging.
@MainActor
@Observable
public final class ActivityModel {
    public struct DaySection: Identifiable, Sendable, Hashable {
        public var id: CalendarDay { day }
        public let day: CalendarDay
        public let title: String
        public let rows: [LedgerTransaction]
    }

    public var query = ActivityQuery()
    public private(set) var state: LoadState<[LedgerTransaction]> = .idle
    public private(set) var total: Int?
    public private(set) var meta: FilterMeta?
    public private(set) var isLoadingMore = false
    public var errorMessage: String?

    private let api: any LedgerAPI
    private var loadToken = 0

    public init(api: any LedgerAPI) { self.api = api }

    public var rows: [LedgerTransaction] { state.value ?? [] }
    public var canLoadMore: Bool { total.map { rows.count < $0 } ?? false }
    public var sections: [DaySection] { Self.sections(rows) }

    /// A failed load with nothing cached shows the error; an empty result shows
    /// "no transactions" only when the server said so.
    public var emptyMessage: String? {
        guard case .loaded(let rows) = state, rows.isEmpty else { return nil }
        return query.searchOrFilter != nil || query.hasFilters
            ? "No transactions match these filters."
            : "No transactions yet. They appear here as SMS and statements arrive."
    }

    public func load(profileCode: String) async {
        loadToken += 1
        let token = loadToken
        query.page = 0
        state = state.startLoading()
        do {
            if meta == nil { meta = try? await api.filterMeta(profileCode: profileCode) }
            let page = try await api.transactions(profileCode: profileCode, query: query)
            guard token == loadToken else { return }   // a newer search superseded this one
            total = page.total
            state = .loaded(page.rows)
        } catch {
            guard token == loadToken else { return }
            state = state.fail(error)
        }
    }

    public func loadMore(profileCode: String) async {
        guard canLoadMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var next = query
        next.page += 1
        do {
            let page = try await api.transactions(profileCode: profileCode, query: next)
            query.page = next.page
            total = page.total
            state = .loaded(Self.merge(rows, page.rows))
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
        }
    }

    public func clearFilters() { query.clearFilters() }

    /// Recategorise one transaction, optionally every transaction from its merchant.
    public func setCategory(_ txn: LedgerTransaction, to categoryCode: String, applyToMerchant: Bool,
                            profileCode: String) async -> Bool {
        do {
            try await api.setTransactionCategory(txnCode: txn.txnCode, categoryCode: categoryCode,
                                                 applyToMerchant: applyToMerchant && txn.merchantCode != nil)
            await load(profileCode: profileCode)
            return true
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
            return false
        }
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

    /// Appends a page, dropping rows already shown (a new SMS shifts offsets).
    nonisolated static func merge(_ existing: [LedgerTransaction], _ page: [LedgerTransaction]) -> [LedgerTransaction] {
        let seen = Set(existing.map(\.txnCode))
        return existing + page.filter { !seen.contains($0.txnCode) }
    }
}

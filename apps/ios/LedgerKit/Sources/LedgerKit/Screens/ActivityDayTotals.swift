import Foundation
import Observation

/// One Activity date header's figures over the whole filtered set
/// (`rpc('activity_day_totals')`, audit MA-3): computed on the server with the
/// same filter reader as the bulk actions, so a day split across two pages
/// reads the same on both (CLAUDE.md §2.2).
public struct DayTotal: Decodable, Sendable, Hashable {
    public let txnDate: CalendarDay
    /// Every matching row that day, as the list shows them.
    public let txnCount: Int
    /// Debits minus credits in AED, pending and posted only.
    public let netAed: Decimal
    public let unpricedCount: Int
    public let hasEstimate: Bool

    public init(txnDate: CalendarDay, txnCount: Int, netAed: Decimal, unpricedCount: Int = 0, hasEstimate: Bool = false) {
        self.txnDate = txnDate
        self.txnCount = txnCount
        self.netAed = netAed
        self.unpricedCount = unpricedCount
        self.hasEstimate = hasEstimate
    }

    /// The header's figure, as the web's `dayTotalLabel`: `"AED 1,235"`,
    /// `"≈ AED 90"` with an estimated rate, `"−AED 40"` for a net credit.
    public var label: String { (hasEstimate ? "≈ " : "") + MoneyFormat.total(netAed) }

    /// `"Net of 3 transactions that day, AED 120"`.
    public var accessibilityLabel: String {
        "Net of \(txnCount) \(txnCount == 1 ? "transaction" : "transactions") that day, \(label)"
    }
}

/// The date headers' totals for the days Activity has loaded: one
/// `activity_day_totals` call per page, for that page's days, with the filter
/// as the web sends it (`ActivityQuery.activityFilter`).
@MainActor
@Observable
public final class ActivityDayTotals {
    /// `activity_day_totals` takes at most this many days per call.
    public nonisolated static let maxDays = 2000

    public private(set) var byDay: [CalendarDay: DayTotal] = [:]

    private struct Key: Hashable {
        let profileCode: String
        let query: ActivityQuery
    }

    private let api: any LedgerAPI
    private var key: Key?
    /// Days asked for (or being asked for) under `key`.
    private var requested: Set<CalendarDay> = []

    public init(api: any LedgerAPI) { self.api = api }

    /// Loads the totals of `days` (in list order) for these filters. Without
    /// `refresh`, days already asked for are skipped (a new page asks only for
    /// its new days); with it they are read again (pull-to-refresh, an edit).
    /// New filters or another ledger start from nothing. A failure leaves the
    /// headers without a figure; it never blocks the list.
    public func load(days: [CalendarDay], profileCode: String, query: ActivityQuery, refresh: Bool = false) async {
        let key = Key(profileCode: profileCode, query: query)
        if key != self.key {
            self.key = key
            byDay = [:]
            requested = []
        }
        let wanted = Self.days(days, skipping: refresh ? [] : requested)
        guard !wanted.isEmpty else { return }
        requested.formUnion(wanted)
        do {
            let rows = try await api.activityDayTotals(profileCode: profileCode, query: query, days: wanted)
            guard self.key == key else { return }
            for day in wanted { byDay[day] = nil }       // a day with no matching row isn't returned
            for row in rows { byDay[row.txnDate] = row }
        } catch {
            guard self.key == key else { return }
            requested.subtract(wanted)                    // asked again with the next page
        }
    }

    public func reset() {
        key = nil
        byDay = [:]
        requested = []
    }

    /// The distinct days, in order, minus `skipping`, at most `maxDays`.
    nonisolated static func days(_ days: [CalendarDay], skipping: Set<CalendarDay>) -> [CalendarDay] {
        var seen = skipping
        var out: [CalendarDay] = []
        for day in days where seen.insert(day).inserted {
            out.append(day)
            if out.count == maxDays { break }
        }
        return out
    }
}

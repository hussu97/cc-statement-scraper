import Foundation
import Observation

/// The Monthly spend card: its filter (which spend counts) and its split:
/// None (plain `spend_series` bars) or `spend_breakdown` by category, bank or
/// merchant. Unfiltered None shows the Insights screen's own trend; any other
/// combination is loaded here, with the filter.
@MainActor
@Observable
public final class SpendSplitModel {
    public var grouping: SpendSplitGrouping = .none {
        didSet { if grouping != oldValue { selectedMonth = nil } }
    }
    /// Applied by the sheet's Done; the card reloads when it changes.
    public var filter = SpendFilter() {
        didSet { if filter != oldValue { selectedMonth = nil } }
    }
    public private(set) var state: LoadState<SpendBreakdown> = .idle
    /// The filtered `spend_series` bars (None + a filter).
    public private(set) var filteredTrend: LoadState<[SpendPoint]> = .idle
    /// The filter sheet's choices (`filter_meta`), nil until loaded.
    public private(set) var options: SpendFilterOptions?
    /// The month label the chart has selected (`"Oct"`), for the callout.
    public var selectedMonth: String?
    public static let topN = 10

    private let api: any LedgerAPI
    private var loadedKey: Key?
    private var loadToken = 0
    /// The ledger the filter's codes and the options belong to.
    private var profileCode: String?

    private struct Key: Hashable {
        let profileCode: String
        let grouping: SpendSplitGrouping
        let from: CalendarDay
        let to: CalendarDay
        let filter: SpendFilter
    }

    public init(api: any LedgerAPI) { self.api = api }

    /// The None bars: the screen's unfiltered trend, or this model's filtered one.
    public func trend(unfiltered: [SpendPoint]) -> LoadState<[SpendPoint]> {
        filter.isEmpty ? .loaded(unfiltered) : filteredTrend
    }

    /// The active filter in words, for the card; nil when unfiltered.
    public var filterSummary: String? { filter.summary(options: options) }

    /// What an empty chart says: the filter, not the period, may be why.
    public var emptyMessage: String {
        filter.isEmpty ? "No spending in this period." : "No spending matches these filters in this period."
    }

    /// Loads what the card shows for the current grouping and filter; a no-op
    /// for unfiltered None and for a request already on screen (unless
    /// `force`, e.g. pull to refresh). Another ledger clears the filter.
    public func load(profileCode: String, from: CalendarDay, to: CalendarDay, force: Bool = false) async {
        adopt(profileCode)
        if grouping == .none && filter.isEmpty { return }
        let key = Key(profileCode: profileCode, grouping: grouping, from: from, to: to, filter: filter)
        let current = grouping == .none ? filteredTrend.isLoaded : state.isLoaded
        if !force, key == loadedKey, current { return }
        loadToken += 1
        let token = loadToken
        let sameKey = loadedKey == key
        loadedKey = key
        if grouping == .none {
            filteredTrend = sameKey ? filteredTrend.startLoading() : .loading(previous: nil)
            do {
                let points = try await api.spendSeries(profileCode: profileCode, from: from, to: to, grain: .month,
                                                       group: .none, filter: filter)
                guard token == loadToken else { return }   // a newer grouping, filter or range superseded this one
                filteredTrend = .loaded(points)
            } catch {
                guard token == loadToken else { return }
                filteredTrend = filteredTrend.fail(error)
            }
        } else {
            state = sameKey ? state.startLoading() : .loading(previous: nil)
            do {
                let result = try await api.spendBreakdown(profileCode: profileCode, from: from, to: to,
                                                          groupBy: grouping, topN: Self.topN, filter: filter)
                guard token == loadToken else { return }
                state = .loaded(result)
            } catch {
                guard token == loadToken else { return }
                state = state.fail(error)
            }
        }
    }

    /// Loads the sheet's choices once per ledger. A failure leaves them nil
    /// (the sheet says so; the filter still works with what is selected).
    public func loadOptions(profileCode: String) async {
        adopt(profileCode)
        guard options == nil, let meta = try? await api.filterMeta(profileCode: profileCode),
              self.profileCode == profileCode else { return }
        options = SpendFilterOptions(meta: meta)
    }

    public func clearFilter() { filter = SpendFilter() }

    private func adopt(_ profileCode: String) {
        guard self.profileCode != profileCode else { return }
        if self.profileCode != nil {
            filter = SpendFilter()
            options = nil
        }
        self.profileCode = profileCode
    }

    public var callout: SpendCallout? {
        guard let selectedMonth, let value = state.value else { return nil }
        return value.callout(forMonthLabel: selectedMonth)
    }
}

/// What an `AXChartDescriptor` needs, built from server figures. The app turns
/// it into the descriptor (Accessibility framework); VoiceOver users get the
/// audio graph and a data table instead of an unlabeled image.
public struct ChartAccessibility: Sendable, Hashable {
    public struct Series: Sendable, Hashable {
        public let name: String
        /// One value per x category, in AED (chart scale only, never money maths).
        public let values: [Double]
    }
    public let title: String
    public let summary: String
    public let xTitle: String
    public let categories: [String]
    public let yTitle: String
    public let series: [Series]

    public var yMax: Double {
        // Stacked: the tallest column is the sum of its positive values.
        let columns = categories.indices.map { i in series.reduce(0) { $0 + max($1.values[safe: i] ?? 0, 0) } }
        return max(columns.max() ?? 0, 1)
    }

    /// The plain monthly bars (`spend_series`, no grouping).
    public static func monthlyTrend(_ points: [SpendPoint]) -> ChartAccessibility {
        let peak = points.max { $0.amount < $1.amount }
        let summary = peak.map { "Highest month \(LedgerDates.monthTitle($0.bucket)), \(MoneyFormat.aed($0.amount, fractionDigits: 0))." }
            ?? "No spending in this period."
        return ChartAccessibility(title: "Monthly spend", summary: summary, xTitle: "Month",
                                  categories: points.map { LedgerDates.monthTitle($0.bucket) }, yTitle: "AED",
                                  series: [.init(name: "Spend", values: points.map(\.amount.chartValue))])
    }

    /// The stacked split: one series per group.
    public static func breakdown(_ b: SpendBreakdown, grouping: SpendSplitGrouping) -> ChartAccessibility {
        let top = b.groups.first
        let summary = top.map {
            "Total \(MoneyFormat.aed(b.total, fractionDigits: 0)). Largest \(grouping.label.lowercased()): \($0.label), \(SpendBreakdown.shareLabel($0.share))."
        } ?? "No spending in this period."
        let titles = b.months.map { CalendarDay(iso: $0 + "-01").map(LedgerDates.monthTitle) ?? $0 }
        let series = b.groups.map { group in
            Series(name: group.label, values: b.series.map { ($0.values[group.key] ?? 0).chartValue })
        }
        return ChartAccessibility(title: "Monthly spend by \(grouping.label.lowercased())", summary: summary,
                                  xTitle: "Month", categories: titles, yTitle: "AED", series: series)
    }

    /// Overview's category ring.
    public static func categoryRing(_ categories: [Overview.TopCategory], total: Decimal) -> ChartAccessibility {
        let summary = categories.first.map { "Total \(MoneyFormat.aed(total, fractionDigits: 0)). Largest: \($0.displayName), \(MoneyFormat.aed($0.amount, fractionDigits: 0))." }
            ?? "No spending this month yet."
        return ChartAccessibility(title: "Spending by category", summary: summary, xTitle: "Category",
                                  categories: categories.map(\.displayName), yTitle: "AED",
                                  series: [.init(name: "Spend", values: categories.map(\.amount.chartValue))])
    }
}

private extension LoadState {
    var isLoaded: Bool { if case .loaded = self { true } else { false } }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

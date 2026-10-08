import Foundation
import Observation

/// The Monthly spend card's split: None (the plain `spend_series` bars the
/// screen already has) or `spend_breakdown` by category, bank or merchant.
@MainActor
@Observable
public final class SpendSplitModel {
    public var grouping: SpendSplitGrouping = .none {
        didSet { if grouping != oldValue { selectedMonth = nil } }
    }
    public private(set) var state: LoadState<SpendBreakdown> = .idle
    /// The month label the chart has selected (`"Oct"`), for the callout.
    public var selectedMonth: String?
    public static let topN = 10

    private let api: any LedgerAPI
    private var loadedKey: String?
    private var loadToken = 0

    public init(api: any LedgerAPI) { self.api = api }

    /// Loads the breakdown for the current grouping; a no-op for None and for
    /// a request already on screen (unless `force`, e.g. pull to refresh).
    public func load(profileCode: String, from: CalendarDay, to: CalendarDay, force: Bool = false) async {
        guard grouping != .none else { return }
        let key = "\(profileCode)|\(grouping.rawValue)|\(from.iso)|\(to.iso)"
        if !force, key == loadedKey, case .loaded = state { return }
        loadToken += 1
        let token = loadToken
        if loadedKey != key { state = .loading(previous: nil) } else { state = state.startLoading() }
        do {
            let result = try await api.spendBreakdown(profileCode: profileCode, from: from, to: to,
                                                      groupBy: grouping, topN: Self.topN)
            guard token == loadToken else { return }   // a newer grouping or range superseded this one
            loadedKey = key
            state = .loaded(result)
        } catch {
            guard token == loadToken else { return }
            loadedKey = key
            state = state.fail(error)
        }
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

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

import Foundation
import Observation

/// One category the drill-down shows: its code (nil: uncategorised spend), name and colour token.
public struct CategoryTarget: Sendable, Hashable {
    public let categoryCode: String?
    public let name: String
    public let colorToken: String?

    public init(categoryCode: String?, name: String, colorToken: String?) {
        self.categoryCode = categoryCode
        self.name = name
        self.colorToken = colorToken
    }

    public init(_ category: CategorySpend) {
        self.init(categoryCode: category.categoryCode, name: category.name, colorToken: category.colorToken)
    }

    public init(_ category: Overview.TopCategory) {
        self.init(categoryCode: category.categoryCode, name: category.displayName, colorToken: category.colorToken)
    }

    /// The spend RPCs' `p_category_codes` value: the code, or `"__uncategorized__"`.
    public var filterKey: String { categoryCode ?? SpendFilter.uncategorized }
}

/// What the drill-down opens (web `/insights/category/$code`): one category over a range. The
/// total, change and merchants cover the range; the trend widens it to whole months.
public struct CategoryDrillDownRequest: Sendable, Hashable, Identifiable {
    public var id: Self { self }
    public let target: CategoryTarget
    public let from: CalendarDay
    public let to: CalendarDay

    /// The fewest months the trend shows, so a one-month range still has history (web `TREND_MIN_MONTHS`).
    public static let trendMinMonths = 6
    /// Merchants the server keeps before folding the rest into Others (web `TOP_MERCHANTS`).
    public static let topMerchants = 8

    public init(target: CategoryTarget, from: CalendarDay, to: CalendarDay) {
        self.target = target
        self.from = from
        self.to = to
    }

    /// The trend's first day: the range's, or earlier so at least `trendMinMonths` whole months
    /// end with the range's last month (web `trendRange`).
    public var trendFrom: CalendarDay {
        let earliest = to.startOfMonth.adding(months: -(Self.trendMinMonths - 1))
        return from < earliest ? from : earliest
    }

    /// The spend the drill-down's `spend_breakdown` calls keep: this category only.
    public var filter: SpendFilter { SpendFilter(categoryCodes: [target.filterKey]) }

    /// `"1 May – 13 Oct"`, with years where they are not this year's or differ.
    public func rangeLabel(today: CalendarDay = LedgerDates.today()) -> String {
        LedgerDates.rangeLabel(from: from, to: to, today: today)
    }

    public func trendRangeLabel(today: CalendarDay = LedgerDates.today()) -> String {
        LedgerDates.rangeLabel(from: trendFrom, to: to, today: today)
    }
}

extension LedgerDates {
    /// `"1 May – 13 Oct"` this year; `"1 May – 31 Oct 2025"` in another year;
    /// `"1 Nov 2025 – 13 Oct 2026"` across years.
    public static func rangeLabel(from: CalendarDay, to: CalendarDay, today: CalendarDay = LedgerDates.today()) -> String {
        if from.year != to.year { return "\(fullDayLabel(from)) – \(fullDayLabel(to))" }
        if to.year != today.year { return "\(dayLabel(from, today: from)) – \(fullDayLabel(to))" }
        return "\(dayLabel(from, today: today)) – \(dayLabel(to, today: today))"
    }
}

/// Everything the drill-down shows, as the server returned it.
public struct CategoryDrillDown: Sendable, Hashable {
    public let request: CategoryDrillDownRequest
    /// The category's `category_breakdown` row for the range; nil when it had no spend there.
    public let row: CategorySpend?
    /// `spend_breakdown` by category, top 1, filtered to the category, over `trendFrom…to`.
    public let trend: SpendBreakdown
    /// `spend_breakdown` by merchant, top 8 + Others, filtered to the category, over the range.
    public let merchants: SpendBreakdown

    public init(request: CategoryDrillDownRequest, row: CategorySpend?, trend: SpendBreakdown, merchants: SpendBreakdown) {
        self.request = request
        self.row = row
        self.trend = trend
        self.merchants = merchants
    }

    /// One month of the trend.
    public struct Bar: Sendable, Hashable, Identifiable {
        public var id: String { month }
        public let month: String
        /// Axis label: `"Oct"` (`"Oct 25"` when the range repeats a month name).
        public let label: String
        /// Readout: `"October 2026"`.
        public let title: String
        public let amount: Decimal
        public var amountLabel: String { MoneyFormat.aed(amount, fractionDigits: 0) }
    }

    /// The trend's months, oldest first, zero-filled by the server; empty when the category had
    /// no spend in any of them.
    public var bars: [Bar] {
        guard !trend.isEmpty else { return [] }
        return trend.series.map { month in
            Bar(month: month.month, label: trend.monthLabel(month.month),
                title: CalendarDay(iso: month.month + "-01").map(LedgerDates.monthTitle) ?? month.month,
                amount: month.total)
        }
    }

    /// The month the readout shows: the selected axis label's, else the latest.
    public func bar(forLabel label: String?) -> Bar? {
        bars.first { $0.label == label } ?? bars.last
    }

    /// One merchant row (or Others, or the unknown-merchant bucket).
    public struct MerchantRow: Sendable, Hashable, Identifiable {
        public var id: String { key }
        public let key: String
        public let label: String
        public let amountLabel: String
        public let shareLabel: String
        /// Bar length against the top merchant (display only), 0…1.
        public let barFraction: Double
        /// Others and the unknown bucket are not one merchant: drawn muted.
        public let isBucket: Bool
    }

    public var merchantRows: [MerchantRow] {
        let top = merchants.groups.first?.share ?? 0
        return merchants.groups.map { g in
            let ratio = top > 0 ? (g.share / top).chartValue : 0
            return MerchantRow(key: g.key, label: g.label, amountLabel: MoneyFormat.aed(g.total, fractionDigits: 0),
                               shareLabel: SpendBreakdown.shareLabel(g.share),
                               barFraction: min(max(ratio, 0.02), 1),
                               isBucket: g.key.hasPrefix("__"))
        }
    }
}

extension CategorySpend {
    /// The server's `change` against the previous period of the same length, in words:
    /// `"+12%"` (more spent: a warning), `"−8%"` (less: good news), `"±0%"`; `"New"` when the
    /// previous period had no spend (null change). Web `formatChange` + `changeTone`.
    public var changeChip: (label: String, tone: Tone) {
        guard let change else { return ("New", .neutral) }
        let pct = MoneyFormat.rounded(change * 100, scale: 0)
        if pct == 0 { return ("±0%", .neutral) }
        let magnitude = MoneyFormat.grouped(pct < 0 ? -pct : pct, fractionDigits: 0)
        return pct > 0 ? ("+\(magnitude)%", .warn) : ("−\(magnitude)%", .positive)
    }

    /// VoiceOver for the change chip: `"Up 20% on the previous period, AED 1,000"`,
    /// `"Down 16% …"`, `"Level with the previous period"`, `"New: nothing the period before"`.
    public var changeAccessibilityLabel: String {
        guard change != nil else { return "New: nothing the period before" }
        let chip = changeChip
        let previous = MoneyFormat.aed(prevAmount, fractionDigits: 0)
        switch chip.tone {
        case .warn: return "Up \(chip.label.dropFirst()) on the previous period, \(previous)"
        case .positive: return "Down \(chip.label.dropFirst()) on the previous period, \(previous)"
        default: return "Level with the previous period, \(previous)"
        }
    }

    /// `"was AED 1,200"`, or `"nothing the period before"` with no previous spend.
    public var previousLabel: String {
        change == nil ? "nothing the period before" : "was \(MoneyFormat.aed(prevAmount, fractionDigits: 0))"
    }

    /// `"9 transactions"`, `"1 transaction"`.
    public var transactionsLabel: String { txnCount == 1 ? "1 transaction" : "\(txnCount) transactions" }

    /// `"42%"` of all spend in the range (`"0.4%"` for a sliver).
    public var shareLabel: String { SpendBreakdown.shareLabel(share ?? 0) }
}

/// The drill-down screen: one category over a range (BACKLOG PAR-5).
@MainActor
@Observable
public final class CategoryDrillDownModel {
    public private(set) var state: LoadState<CategoryDrillDown> = .idle
    /// The trend's selected axis label (`"Oct"`); nil shows the latest month.
    public var selectedMonth: String?
    private let api: any LedgerAPI
    private var gate = RequestGate<Key>()

    struct Key: Hashable, Sendable {
        let profileCode: String
        let request: CategoryDrillDownRequest
    }

    public init(api: any LedgerAPI) { self.api = api }

    /// The month the trend's readout shows.
    public var readout: CategoryDrillDown.Bar? { state.value?.bar(forLabel: selectedMonth) }

    public func load(profileCode: String, request: CategoryDrillDownRequest) async {
        let key = Key(profileCode: profileCode, request: request)
        let (ticket, sameKey) = gate.begin(key)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        let filter = request.filter
        do {
            async let rows = api.categoryBreakdown(profileCode: profileCode, from: request.from, to: request.to)
            async let trend = api.spendBreakdown(profileCode: profileCode, from: request.trendFrom, to: request.to,
                                                 groupBy: .category, topN: 1, filter: filter)
            async let merchants = api.spendBreakdown(profileCode: profileCode, from: request.from, to: request.to,
                                                     groupBy: .merchant, topN: CategoryDrillDownRequest.topMerchants,
                                                     filter: filter)
            let (r, t, m) = try await (rows, trend, merchants)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(key)
            let row = r.first { $0.categoryCode == request.target.categoryCode }
            state = .loaded(CategoryDrillDown(request: request, row: row, trend: t, merchants: m))
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    /// Loads unless this request is already on screen or loading.
    public func loadIfNeeded(profileCode: String, request: CategoryDrillDownRequest) async {
        let key = Key(profileCode: profileCode, request: request)
        guard gate.requested != key || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode, request: request)
    }
}

/// Makes a drill-down model for each pushed screen; the app puts one in the environment so
/// Overview and Insights can both push the screen.
@MainActor
@Observable
public final class CategoryDrillDowns {
    @ObservationIgnored private let api: any LedgerAPI

    public init(api: any LedgerAPI) { self.api = api }

    public func makeModel() -> CategoryDrillDownModel { CategoryDrillDownModel(api: api) }
}

extension Overview {
    /// The drill-down for one of the ring's categories: the month on screen, first to last day
    /// (web: the ring links with `from = month`, `to = monthEnd(month)`).
    public func drillDown(_ category: TopCategory) -> CategoryDrillDownRequest {
        CategoryDrillDownRequest(target: CategoryTarget(category), from: month.startOfMonth, to: month.endOfMonth)
    }

    /// The ring slice under a chart angle value (the running total of the slices' amounts, as
    /// Swift Charts reports a `SectorMark` selection). Display geometry only.
    public static func ringCategory(_ categories: [TopCategory], atAngleValue value: Double) -> TopCategory? {
        var running = 0.0
        for category in categories {
            running += category.amount.chartValue
            if value <= running { return category }
        }
        return categories.last
    }
}

extension ChartAccessibility {
    /// The drill-down's monthly bars.
    public static func categoryTrend(_ d: CategoryDrillDown) -> ChartAccessibility {
        let bars = d.bars
        let peak = bars.max { $0.amount < $1.amount }
        let summary = peak.map { "Highest month \($0.title), \($0.amountLabel)." } ?? "No spending in these months."
        return ChartAccessibility(title: "\(d.request.target.name) by month", summary: summary, xTitle: "Month",
                                  categories: bars.map(\.title), yTitle: "AED",
                                  series: [.init(name: d.request.target.name, values: bars.map(\.amount.chartValue))])
    }
}

import Foundation
import Observation

/// Insights → Trends (BACKLOG PAR-10, the web's Insights "Trends" tab): spend over a range in
/// day, week or month buckets, as a total or split by category, bank, merchant, account or
/// card, over the spend `filter` keeps. `spend_series` answers everything but Bank, which is
/// `spend_breakdown`'s (monthly only); the bucket totals are always the server's.
@MainActor
@Observable
public final class TrendsModel {
    /// Groups beyond this many fold into "Other" on the server (the web's `TOP_GROUPS`).
    public static let topGroups = 8

    public private(set) var range: TrendsRange
    /// The reader picked Custom range (the dates show even while they equal a preset).
    public private(set) var customOpen = false
    public var group: TrendsGroup = .category {
        didSet { if group != oldValue { selectedBucket = nil } }
    }
    /// The reader's bucket size; nil follows the range (`TrendsRange.defaultGrain`).
    public private(set) var chosenGrain: SpendGrain?
    public var filter = SpendFilter() {
        didSet { if filter != oldValue { selectedBucket = nil } }
    }
    public private(set) var state: LoadState<TrendsSeries> = .idle
    /// The filter sheet's choices (`filter_meta`), nil until loaded.
    public private(set) var options: SpendFilterOptions?
    /// The bucket the chart or table has selected (its ISO start).
    public var selectedBucket: String?

    private let api: any LedgerAPI
    private let today: @Sendable () -> CalendarDay
    private var gate = RequestGate<TrendsRequest>()
    /// The ledger the filter's codes and the options belong to.
    private var profileCode: String?

    public init(api: any LedgerAPI, preset: TrendsPreset = .last6Months,
                today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() }) {
        self.api = api
        self.today = today
        range = .preset(preset, today: today())
    }

    // MARK: - Choices

    public var rangeChoice: TrendsRangeChoice {
        get { customOpen || range.preset == nil ? .custom : .preset(range.preset!) }
        set {
            switch newValue {
            case .preset(let preset):
                customOpen = false
                setRange(.preset(preset, today: today()))
            case .custom:
                customOpen = true
            }
        }
    }

    public var customFrom: CalendarDay {
        get { range.from }
        set { setRange(.custom(from: newValue, to: max(newValue, range.to), today: today())) }
    }

    public var customTo: CalendarDay {
        get { range.to }
        set { setRange(.custom(from: min(range.from, newValue), to: newValue, today: today())) }
    }

    /// The latest day a custom range may end on.
    public var latestDay: CalendarDay { today() }

    /// The bucket size on screen: the reader's when it suits the range and grouping.
    public var grain: SpendGrain {
        get { group.monthlyOnly ? .month : range.grain(choosing: chosenGrain) }
        set {
            guard newValue != grain else { return }
            chosenGrain = newValue
            selectedBucket = nil
        }
    }

    /// The bucket sizes offered: the range's (`TrendsRange.grains`); Bank is monthly only.
    public var grainOptions: [SpendGrain] { group.monthlyOnly ? [.month] : range.grains }

    /// The active filter in words, for the card; nil when unfiltered.
    public var filterSummary: String? { filter.summary(options: options) }

    public func clearFilter() { filter = SpendFilter() }

    /// What an empty chart says: the filter, not the range, may be why.
    public var emptyMessage: String {
        filter.isEmpty ? "No spending in this range. Pick a longer range, or check that your cards are syncing."
            : "Nothing in this range matches every filter. Remove one, or pick a longer range."
    }

    /// The selected bucket, if it is on screen.
    public var selected: TrendsSeries.Bucket? { state.value?.bucket(id: selectedBucket) }

    /// Selects a bucket, or clears it when it is already selected.
    public func toggleBucket(_ id: String) {
        selectedBucket = selectedBucket == id ? nil : id
    }

    /// What the screen shows for `profileCode` now; the view's `.task(id:)`.
    public func request(profileCode: String) -> TrendsRequest {
        TrendsRequest(profileCode: profileCode, range: range, grain: grain, group: group, filter: filter)
    }

    private func setRange(_ new: TrendsRange) {
        guard new != range else { return }
        range = new
        selectedBucket = nil
    }

    // MARK: - Loading

    /// Loads the chart for the current choices, unless it is already on screen (`force`: pull
    /// to refresh). Another ledger clears the filter.
    public func load(profileCode: String, force: Bool = false) async {
        adopt(profileCode)
        let key = request(profileCode: profileCode)
        if !force, gate.loaded == key, state.value != nil, !state.isLoading { return }
        let (ticket, _) = gate.begin(key)
        // The previous chart stays, dimmed, until the new one lands (the web's keepPreviousData).
        state = state.startLoading()
        do {
            let series = try await fetch(key)
            guard gate.isCurrent(ticket) else { return }   // a newer range, grouping or filter superseded this one
            gate.finish(key)
            state = .loaded(series)
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    private func fetch(_ key: TrendsRequest) async throws -> TrendsSeries {
        let (range, from, to) = (key.range, key.range.from, key.range.to)
        guard let seriesGroup = key.group.seriesGroup else {
            let breakdown = try await api.spendBreakdown(profileCode: key.profileCode, from: from, to: to,
                                                         groupBy: .bank, topN: SpendSplitModel.topN, filter: key.filter)
            return TrendsSeries(range: range, breakdown: breakdown)
        }
        async let totals = api.spendSeries(profileCode: key.profileCode, from: from, to: to, grain: key.grain,
                                           group: .none, top: nil, filter: key.filter)
        if seriesGroup == .none {
            return try await TrendsSeries(range: range, grain: key.grain, group: key.group, totals: totals, grouped: [])
        }
        async let grouped = api.spendSeries(profileCode: key.profileCode, from: from, to: to, grain: key.grain,
                                            group: seriesGroup, top: Self.topGroups, filter: key.filter)
        return try await TrendsSeries(range: range, grain: key.grain, group: key.group, totals: totals, grouped: grouped)
    }

    /// Loads the filter sheet's choices once per ledger. A failure leaves them nil (the sheet
    /// says so; the filter still works with what is selected).
    public func loadOptions(profileCode: String) async {
        adopt(profileCode)
        guard options == nil, let meta = try? await api.filterMeta(profileCode: profileCode),
              self.profileCode == profileCode else { return }
        options = SpendFilterOptions(meta: meta)
    }

    private func adopt(_ code: String) {
        guard profileCode != code else { return }
        if profileCode != nil {
            filter = SpendFilter()
            options = nil
            gate.reset()
            state = .idle
        }
        profileCode = code
    }
}

/// One Trends request: what the chart shows.
public struct TrendsRequest: Hashable, Sendable {
    public let profileCode: String
    public let range: TrendsRange
    public let grain: SpendGrain
    public let group: TrendsGroup
    public let filter: SpendFilter
}

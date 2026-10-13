import Foundation
import Observation

/// A chip's words and tone.
public struct AnalysisChip: Sendable, Hashable {
    public let label: String
    public let tone: Tone

    public init(_ label: String, _ tone: Tone) {
        self.label = label
        self.tone = tone
    }
}

/// The days an analysis screen covers: Insights' period, as `InsightsModel.range` makes it.
public struct AnalysisRange: Sendable, Hashable {
    public let from: CalendarDay
    public let to: CalendarDay

    public init(from: CalendarDay, to: CalendarDay) {
        self.from = from
        self.to = to
    }

    /// `"1 May – 14 Oct"`.
    public func label(today: CalendarDay = LedgerDates.today()) -> String {
        LedgerDates.rangeLabel(from: from, to: to, today: today)
    }
}

/// One analysis screen's data: loads `Request` for a ledger and keeps the newest answer
/// (a superseded request never overwrites a newer one).
@MainActor
@Observable
public final class AnalysisLoader<Request: Hashable & Sendable, Value: Sendable> {
    public private(set) var state: LoadState<Value> = .idle
    @ObservationIgnored private let fetch: @Sendable (String, Request) async throws -> Value
    @ObservationIgnored private var gate = RequestGate<Key>()

    struct Key: Hashable, Sendable {
        let profileCode: String
        let request: Request
    }

    public init(fetch: @escaping @Sendable (String, Request) async throws -> Value) {
        self.fetch = fetch
    }

    public func load(profileCode: String, request: Request) async {
        let key = Key(profileCode: profileCode, request: request)
        let (ticket, sameKey) = gate.begin(key)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        do {
            let value = try await fetch(profileCode, request)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(key)
            state = .loaded(value)
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    /// Loads unless this request is already on screen or loading.
    public func loadIfNeeded(profileCode: String, request: Request) async {
        let key = Key(profileCode: profileCode, request: request)
        guard gate.requested != key || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode, request: request)
    }
}

/// Makes the "More analysis" screens' loaders (BACKLOG PAR-12); the app puts one in the
/// environment, as it does `CategoryDrillDowns`.
@MainActor
@Observable
public final class AnalysisScreens {
    @ObservationIgnored private let api: any LedgerAPI
    @ObservationIgnored private let today: @Sendable () -> CalendarDay

    public init(api: any LedgerAPI, today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() }) {
        self.api = api
        self.today = today
    }

    /// The current Dubai year: the year-over-year screen opens on it.
    public var currentYear: Int { today().year }

    /// `daily_spend` through the range's end or today, whichever is first, as a calendar.
    public func calendar() -> AnalysisLoader<AnalysisRange, SpendCalendar> {
        let (api, today) = (api, today)
        return AnalysisLoader { code, range in
            let now = today()
            let end = min(range.to, now)
            guard range.from <= end else { return SpendCalendar(rows: [], from: range.from, to: range.to, today: now) }
            let rows = try await api.dailySpend(profileCode: code, from: range.from, to: end)
            return SpendCalendar(rows: rows, from: range.from, to: range.to, today: now)
        }
    }

    public func hours() -> AnalysisLoader<AnalysisRange, HourPattern> {
        let api = api
        return AnalysisLoader { code, range in
            HourPattern(rows: try await api.hourWeekdayPattern(profileCode: code, from: range.from, to: range.to))
        }
    }

    /// Keyed by the year shown.
    public func yearOverYear() -> AnalysisLoader<Int, YearComparison> {
        let api = api
        return AnalysisLoader { code, year in
            YearComparison(year: year, rows: try await api.yearOverYear(profileCode: code, year: year))
        }
    }

    public func foreignSpend() -> AnalysisLoader<AnalysisRange, [ForeignSpendRow]> {
        let api = api
        return AnalysisLoader { code, range in
            ForeignSpendRow.rows(try await api.fxSpend(profileCode: code, from: range.from, to: range.to))
        }
    }
}

import Foundation
import Observation

/// The month Overview and Insights show, shared so the two tabs agree. `nil`
/// means "the current month" and follows the Dubai calendar across midnight on
/// the 1st; a past month stays put.
@MainActor
@Observable
public final class MonthSelection {
    public private(set) var selected: CalendarDay?
    /// The ledger's earliest transaction date (`filter_meta.date_range.min`).
    public private(set) var firstDay: CalendarDay?
    private let today: @Sendable () -> CalendarDay

    public init(today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() }) {
        self.today = today
    }

    public var range: MonthRange { MonthRange(firstDay: firstDay, today: today()) }

    /// First day of the month on screen.
    public var month: CalendarDay { selected.map(range.clamp) ?? range.latest }

    public var isCurrent: Bool { month == range.latest }

    /// What to send as `p_month`: nil for the current month, so the server
    /// uses its own today (`public.dubai_date()`).
    public var requestMonth: CalendarDay? { isCurrent ? nil : month }

    public var canGoBack: Bool { month > range.earliest }
    public var canGoForward: Bool { month < range.latest }

    public var title: String { LedgerDates.monthTitle(month) }

    public func goBack() { if canGoBack { select(month.adding(months: -1)) } }
    public func goForward() { if canGoForward { select(month.adding(months: 1)) } }

    /// Picks a month, clamped to the range; the current month is stored as nil.
    public func select(_ month: CalendarDay) {
        let clamped = range.clamp(month)
        selected = clamped == range.latest ? nil : clamped
    }

    public func setFirstDay(_ day: CalendarDay?) { firstDay = day }

    /// A new ledger starts on its current month.
    public func reset() {
        selected = nil
        firstDay = nil
    }

    // MARK: VoiceOver

    public var previousLabel: String {
        canGoBack ? "Previous month, \(LedgerDates.monthTitle(month.adding(months: -1)))" : "Previous month"
    }

    public var nextLabel: String {
        canGoForward ? "Next month, \(LedgerDates.monthTitle(month.adding(months: 1)))" : "Next month"
    }

    /// The title button: `"Month, September 2026"`; adjustable with swipe up/down.
    public var accessibilityLabel: String { "Month" }
    public var accessibilityValue: String { isCurrent ? "\(title), current month" : title }
}

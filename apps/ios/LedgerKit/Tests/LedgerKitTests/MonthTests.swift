import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

/// A `today` the test can move.
private final class Today: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CalendarDay
    init(_ iso: String) { value = day(iso) }
    var now: CalendarDay {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Suite("Months: range, labels, Dubai calendar")
struct MonthRangeTests {
    @Test("from the ledger's first transaction to the current month, newest first")
    func range() {
        let r = MonthRange(firstDay: day("2025-11-17"), today: day("2026-02-08"))
        #expect(r.earliest == day("2025-11-01") && r.latest == day("2026-02-01"))
        #expect(r.months == [day("2026-02-01"), day("2026-01-01"), day("2025-12-01"), day("2025-11-01")])
        #expect(r.years.map(\.title) == ["2026", "2025"])
        #expect(r.years[1].months == [day("2025-12-01"), day("2025-11-01")])
        #expect(r.contains(day("2025-11-30")) && !r.contains(day("2025-10-31")) && !r.contains(day("2026-03-01")))
        #expect(r.clamp(day("2024-05-05")) == day("2025-11-01"))
        #expect(r.clamp(day("2027-05-05")) == day("2026-02-01"))
    }

    @Test("unknown history allows 24 months; an empty or future first day allows only this month")
    func fallback() {
        let r = MonthRange(firstDay: nil, today: day("2026-10-08"))
        #expect(r.earliest == day("2024-10-01") && r.months.count == 25)
        #expect(MonthRange(firstDay: day("2026-12-01"), today: day("2026-10-08")).months == [day("2026-10-01")])
    }

    @Test("labels: this month, a month this year, a month of another year")
    func labels() {
        let today = day("2026-10-08")
        #expect(LedgerDates.monthScopeLabel(day("2026-10-01"), today: today) == "This month")
        #expect(LedgerDates.monthScopeLabel(day("2026-09-01"), today: today) == "September 2026")
        #expect(LedgerDates.monthPhrase(day("2026-10-01"), today: today) == "this month")
        #expect(LedgerDates.monthPhrase(day("2026-09-01"), today: today) == "in September")
        #expect(LedgerDates.monthPhrase(day("2025-12-01"), today: today) == "in December 2025")
        #expect(LedgerDates.monthName(day("2026-02-01")) == "February")
    }

    @Test("the current month is Dubai's: 21:00 UTC on 31 Oct is already November")
    func dubaiMonth() throws {
        let f = ISO8601DateFormatter()
        let now = try #require(f.date(from: "2026-10-31T21:00:00Z"))
        let today = LedgerDates.today(now: now)
        #expect(MonthRange(firstDay: nil, today: today).latest == day("2026-11-01"))
    }

    @Test("Insights' period ends with the month on screen")
    func insightsRange() {
        let today = day("2026-10-08")
        let current = InsightsModel.range(for: .threeMonths, month: nil, today: today)
        #expect(current.from == day("2026-08-01") && current.to == today)
        let past = InsightsModel.range(for: .sixMonths, month: day("2026-03-01"), today: today)
        #expect(past.from == day("2025-10-01") && past.to == day("2026-03-31"))
        let leap = InsightsModel.range(for: .threeMonths, month: day("2028-02-01"), today: day("2028-06-01"))
        #expect(leap.to == day("2028-02-29"))
        #expect(InsightsModel.periodCaption(.sixMonths, month: nil, today: today) == "Last 6 months to today")
        #expect(InsightsModel.periodCaption(.threeMonths, month: day("2026-03-01"), today: today)
                == "Last 3 months to March 2026")
    }
}

@MainActor
@Suite("Month switcher")
struct MonthSelectionTests {
    @Test("starts on the current month, which is sent to the server as nil")
    func startsCurrent() {
        let m = MonthSelection(today: { day("2026-10-08") })
        #expect(m.month == day("2026-10-01") && m.isCurrent && m.requestMonth == nil)
        #expect(m.title == "October 2026")
        #expect(!m.canGoForward && m.canGoBack)
        #expect(m.accessibilityValue == "October 2026, current month")
        #expect(m.nextLabel == "Next month")
        #expect(m.previousLabel == "Previous month, September 2026")
    }

    @Test("back and forward, never past the current month or before the first transaction")
    func bounds() {
        let m = MonthSelection(today: { day("2026-10-08") })
        m.setFirstDay(day("2026-08-20"))
        m.goBack()
        #expect(m.month == day("2026-09-01") && m.requestMonth == day("2026-09-01"))
        #expect(m.nextLabel == "Next month, October 2026")
        m.goBack()
        #expect(m.month == day("2026-08-01") && !m.canGoBack)
        m.goBack()
        #expect(m.month == day("2026-08-01"))
        m.goForward()
        m.goForward()
        #expect(m.isCurrent && m.selected == nil)
        m.goForward()
        #expect(m.isCurrent)
    }

    @Test("picking a month clamps it; picking the current month follows the calendar again")
    func select() {
        let m = MonthSelection(today: { day("2026-10-08") })
        m.select(day("2027-01-15"))
        #expect(m.isCurrent && m.selected == nil)
        m.select(day("2026-05-31"))
        #expect(m.month == day("2026-05-01") && m.accessibilityValue == "May 2026")
        m.select(day("2026-10-08"))
        #expect(m.selected == nil)
    }

    @Test("the current month rolls over at Dubai midnight on the 1st; a past month stays put")
    func rollover() {
        let today = Today("2026-10-31")
        let m = MonthSelection(today: { today.now })
        let past = MonthSelection(today: { today.now })
        past.select(day("2026-09-01"))
        today.now = day("2026-11-01")
        #expect(m.month == day("2026-11-01") && m.isCurrent)
        #expect(past.month == day("2026-09-01") && !past.isCurrent)
    }

    @Test("a new ledger starts on its current month")
    func reset() {
        let m = MonthSelection(today: { day("2026-10-08") })
        m.setFirstDay(day("2025-01-01"))
        m.select(day("2025-06-01"))
        m.reset()
        #expect(m.isCurrent && m.firstDay == nil)
    }
}

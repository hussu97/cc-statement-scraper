import Foundation
import Testing
@testable import LedgerKit

@Suite("Dates — en_US_POSIX, Asia/Dubai")
struct DateTests {
    @Test("calendar days parse, compare and do arithmetic")
    func calendarDay() throws {
        let day = try #require(CalendarDay(iso: "2026-01-31"))
        #expect(day.iso == "2026-01-31")
        #expect(day.adding(days: 1).iso == "2026-02-01")
        #expect(day.adding(months: 1).iso == "2026-02-28")
        #expect(day.endOfMonth.iso == "2026-01-31")
        #expect(CalendarDay(year: 2028, month: 2, day: 3).endOfMonth.iso == "2028-02-29")
        #expect(day.startOfMonth.adding(months: -5).iso == "2025-08-01")
        #expect(CalendarDay(iso: "2026-13-01") == nil)
        #expect(day < day.adding(days: 1))
        #expect(day.days(until: CalendarDay(iso: "2026-02-10")!) == 10)
    }

    @Test("the business date is the Dubai calendar day, not UTC's")
    func dubaiBoundary() throws {
        // 21:30 UTC on 7 Oct is 01:30 on 8 Oct in Dubai (UTC+4).
        let instant = try #require(LedgerDates.parseTimestamp("2026-10-07T21:30:00+00:00"))
        #expect(CalendarDay(date: instant).iso == "2026-10-08")
        #expect(LedgerDates.timeLabel(instant) == "01:30")
        #expect(LedgerDates.today(now: instant).iso == "2026-10-08")
    }

    @Test("every timestamp shape Postgres emits parses", arguments: [
        "2026-10-08T05:12:44.123456+00:00",
        "2026-10-08T05:12:44+00:00",
        "2026-10-08T09:12:44+04:00",
        "2026-10-08 09:12:44+04",
        "2026-10-08T05:12:44Z",
        "2026-10-08T05:12:44.1Z",
    ])
    func timestamps(raw: String) throws {
        let date = try #require(LedgerDates.parseTimestamp(raw))
        #expect(Int(date.timeIntervalSince1970) == 1_791_436_364)
    }

    @Test("labels use POSIX digits and English month names")
    func labels() throws {
        let today = try #require(CalendarDay(iso: "2026-10-08"))
        #expect(LedgerDates.dayLabel(CalendarDay(iso: "2026-10-03")!, today: today) == "3 Oct")
        #expect(LedgerDates.dayLabel(CalendarDay(iso: "2025-12-31")!, today: today) == "31 Dec 2025")
        #expect(LedgerDates.relativeDayLabel(today, today: today) == "Today")
        #expect(LedgerDates.relativeDayLabel(today.adding(days: -1), today: today) == "Yesterday")
        #expect(LedgerDates.monthTitle(today) == "October 2026")
        #expect(LedgerDates.monthAbbrev(today) == "Oct")
    }

    @Test func dueLabels() throws {
        let today = try #require(CalendarDay(iso: "2026-10-08"))
        #expect(LedgerDates.dueLabel(today, today: today) == "Due today")
        #expect(LedgerDates.dueLabel(today.adding(days: 1), today: today) == "Due tomorrow")
        #expect(LedgerDates.dueLabel(today.adding(days: 12), today: today) == "Due in 12 days")
        #expect(LedgerDates.dueLabel(today.adding(days: -1), today: today) == "Overdue by 1 day")
        #expect(LedgerDates.dueLabel(today.adding(days: -3), today: today) == "Overdue by 3 days")
    }

    @Test("received_at goes out as ISO-8601 with milliseconds and parses back")
    func isoRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_791_436_364.25)
        let text = LedgerDates.isoTimestamp(date)
        #expect(text == "2026-10-08T05:12:44.250Z")
        #expect(LedgerDates.parseTimestamp(text) == date)
    }
}

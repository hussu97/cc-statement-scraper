import Foundation
import Testing
@testable import LedgerKit

private func day(_ m: Int, _ d: Int, _ y: Int = 2026) -> CalendarDay { CalendarDay(year: y, month: m, day: d) }
private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Analysis (PAR-12) — heat shades and the calendar")
struct AnalysisCalendarTests {
    @Test("quantile cut points and levels mirror the web's heat.ts")
    func heatScale() {
        let scale = HeatScale(values: [0, dec("86.40"), 312, dec("1240.75"), -45])
        #expect(scale.thresholds == [dec("86.40"), 312, dec("1240.75")])
        #expect([0, -45, 10, dec("86.40"), 312, 5000].map(scale.level) == [0, 0, 1, 2, 3, 4])
        #expect(HeatScale(values: [0, 0]).thresholds.isEmpty)
        #expect(HeatScale(values: [5]).level(5) == 4)   // one value: every cut point is it
        #expect([0, 1, 2, 4, 9].map(HeatScale.intensity) == [0, 0.25, 0.5, 1, 1])
    }

    @Test("months newest first, Monday-first weeks, out-of-range and future days blank")
    func layout() throws {
        let rows = try LedgerJSON.decode([DailySpend].self, from: try fixture("daily_spend"))
        let cal = SpendCalendar(rows: rows, from: day(9, 29), to: day(10, 20), today: day(10, 3))
        #expect(cal.to == day(10, 3))
        #expect(cal.months.map(\.title) == ["October 2026", "September 2026"])
        let october = cal.months[0]
        #expect(october.weeks.count == 5)
        #expect(october.weeks.allSatisfy { $0.count == 7 })
        // 1 Oct 2026 is a Thursday: three blanks first, then 1–3 Oct, then nothing (the future).
        #expect(october.weeks[0].map { $0?.day.day } == [nil, nil, nil, 1, 2, 3, nil])
        #expect(october.weeks.dropFirst().allSatisfy { $0.allSatisfy { $0 == nil } })
        // 1 Sep is a Tuesday; only 29 and 30 Sep are in the range.
        let september = cal.months[1]
        #expect(september.weeks.flatMap { $0 }.compactMap { $0?.day.day } == [29, 30])
        #expect(september.weeks.last?.map { $0?.day.day } == [nil, 29, 30, nil, nil, nil, nil])
        #expect(cal.cell(for: day(9, 30))?.level == 4)
        #expect(cal.cell(for: day(10, 2))?.level == 0)
        #expect(cal.cell(for: day(10, 4)) == nil)
        #expect(cal.summary == "Spent on 3 days of 5.")
        #expect(!cal.isEmpty)
    }

    @Test("words for a day, and its Activity link")
    func words() throws {
        let cell = SpendCalendar.Cell(day: day(10, 3), amount: 312, txnCount: 2, level: 3)
        #expect(SpendCalendar.label(cell, today: day(10, 14)) == "Sat 3 Oct: AED 312, 2 transactions")
        let one = SpendCalendar.Cell(day: day(12, 31, 2025), amount: dec("0.30"), txnCount: 1, level: 1)
        #expect(SpendCalendar.label(one, today: day(10, 14)) == "Wed 31 Dec 2025: AED 0.30, 1 transaction")
        let query = ActivityQuery.onDay(day(10, 3))
        #expect(query.from == day(10, 3) && query.to == day(10, 3))
        #expect(query.hasFilters)
    }

    @Test("all-zero days prove the empty state; a range in the future draws nothing")
    func empty() {
        let zero = SpendCalendar(rows: [DailySpend(day: day(10, 1), amount: 0, txnCount: 0)],
                                 from: day(10, 1), to: day(10, 1), today: day(10, 14))
        #expect(zero.isEmpty)
        #expect(zero.months.count == 1)
        let future = SpendCalendar(rows: [], from: day(11, 1), to: day(11, 30), today: day(10, 14))
        #expect(future.months.isEmpty)
        #expect(future.isEmpty)
    }

    @Test("ISO weekdays in Dubai")
    func weekdays() {
        #expect(AnalysisFormat.isoWeekday(day(10, 12)) == 1)   // Monday
        #expect(AnalysisFormat.isoWeekday(day(10, 18)) == 7)   // Sunday
        #expect(AnalysisFormat.dayTitle(day(10, 14), today: day(10, 14)) == "Wed 14 Oct")
        #expect(AnalysisFormat.count(1204, "transaction") == "1,204 transactions")
        #expect(AnalysisFormat.total(dec("1240.75")) == "AED 1,241")
        #expect(AnalysisFormat.total(0) == "AED 0")
        #expect(AnalysisFormat.total(dec("4500"), currency: "JPY") == "JPY 4,500")
    }
}

@Suite("Analysis (PAR-12) — time of day, year over year, foreign currency")
struct AnalysisPatternTests {
    @Test("the hour grid places cells by ISO weekday and hour, and words them as the web")
    func hourGrid() throws {
        let rows = try LedgerJSON.decode([HourWeekdaySpend].self, from: try fixture("hour_weekday_pattern"))
        let grid = HourPattern(rows: rows)
        #expect(grid.rows.count == 7 && grid.rows.allSatisfy { $0.count == 24 })
        #expect(grid.cell(dow: 1, hour: 9)?.level == 3)
        #expect(grid.cell(dow: 5, hour: 21)?.level == 4)
        #expect(grid.cell(dow: 2, hour: 9) == nil)
        #expect(grid.readout(dow: 1, hour: 9) == "Monday, 09:00–10:00 · AED 120 · 2 transactions")
        #expect(grid.readout(dow: 7, hour: 0) == "Sunday, 00:00–01:00 · AED 15 · 1 transaction")
        #expect(grid.readout(dow: 2, hour: 9) == nil)
        #expect(grid.accessibilityLabel(dow: 2, hour: 9) == "Tuesday 09:00: AED 0, 0 transactions")
        #expect(HourPattern.slotLabel(dow: 5, hour: 23) == "Friday, 23:00–00:00")
        #expect(HourPattern.hourLabels.prefix(4) == ["00", "", "", "03"])
        #expect(HourPattern.hourLabels.filter { !$0.isEmpty }.count == 8)
        #expect(!grid.isEmpty)
        #expect(HourPattern(rows: []).isEmpty)
    }

    @Test("year over year: title, readout and change against the year before")
    func yearOverYear() throws {
        let rows = try LedgerJSON.decode([YearOverYearMonth].self, from: try fixture("yoy_compare"))
        let yoy = YearComparison(year: 2026, rows: rows.reversed())
        let today = day(10, 14)
        #expect(yoy.title == "2026 against 2025")
        #expect(yoy.months.map(\.label).prefix(3) == ["Jan", "Feb", "Mar"])
        #expect(yoy.months.first?.title == "January")
        #expect(!yoy.isEmpty)
        let jan = try #require(yoy.readout(month: 1, today: today))
        #expect(jan.title == "January")
        #expect(jan.thisYear == "2026  AED 8,120")
        #expect(jan.lastYear == "2025  AED 7,400")
        #expect(jan.change == AnalysisChip("+10%", .warn))
        #expect(yoy.readout(month: 2, today: today)?.change == AnalysisChip("±0%", .neutral))
        #expect(yoy.readout(month: 3, today: today)?.change == AnalysisChip("−10%", .positive))
        #expect(yoy.readout(month: 4, today: today)?.change == AnalysisChip("New", .neutral))
        let now = try #require(yoy.readout(month: nil, today: today))
        #expect(now.title == "October so far")
        #expect(now.change == AnalysisChip("−67%", .positive))
        #expect(yoy.readout(month: 11, today: today)?.change == nil)   // still to come
        #expect(YearComparison(year: 2025, rows: rows).readout(month: nil, today: today)?.title == "December")
        #expect(YearComparison.yearOptions(currentYear: 2026) == [2026, 2025, 2024, 2023, 2022, 2021])
        #expect(yoy.accessibility.series.map(\.name) == ["2026", "2025"])
        #expect(yoy.accessibility.categories.count == 12)
    }

    @Test("an all-zero year proves the empty state")
    func yearEmpty() {
        let zero = YearComparison(year: 2026, rows: (1...12).map { YearOverYearMonth(month: $0, thisYear: 0, lastYear: 0) })
        #expect(zero.isEmpty)
        #expect(zero.emptyTitle == "No spending in 2026 or 2025")
        #expect(YearComparison(year: 2026, rows: []).isEmpty)
    }

    @Test("foreign currency: amounts, the rate paid and the estimate badge in words")
    func foreign() throws {
        let rows = ForeignSpendRow.rows(try LedgerJSON.decode([FxSpend].self, from: try fixture("fx_spend")))
        #expect(rows.map(\.amountAedLabel) == ["AED 1,240", "AED 488", "AED 112", "AED 0"])
        #expect(rows.map(\.originalLabel) == ["USD 338", "EUR 120", "JPY 4,500", "GBP 0"])
        #expect(rows.map(\.rateLabel) == ["1 USD = 3.6730 AED", "1 EUR = 4.0660 AED", "1 JPY = 0.0249 AED", nil])
        #expect(rows.map(\.estimateLabel) == [nil, "40% estimated", "Estimated", nil])
        #expect(rows[1].estimateNote == "40% of these transactions use an estimated rate; AED 488 may move when statements arrive.")
        #expect(rows[0].countLabel == "5 transactions")
    }
}

@Suite("Analysis (PAR-12) — the full subscriptions list")
struct AnalysisSubscriptionTests {
    @Test("every charge, active first as the server orders them, in the web's words")
    func list() throws {
        let charges = try LedgerJSON.decode([RecurringCharge].self, from: try fixture("recurring_list"))
        let list = SubscriptionList(charges, today: day(10, 14))
        #expect(list.headline == "2 active charges · 2 ended or dismissed")
        let rows = list.rows
        #expect(rows.map(\.merchantName) == ["Netflix", "Gym Nation", "Careem Plus", "Cloud Storage"])
        #expect(rows.map(\.statusBadge) == [nil, nil, "Dismissed", "Ended"])
        #expect(rows[0].detail == "Monthly · Subscriptions · 7 charges")
        #expect(rows[1].detail == "Monthly · 4 charges")
        #expect(rows[0].expectedLabel == "AED 45.00 / month")
        #expect(rows[2].expectedLabel == "AED 19.00 / week")
        #expect(rows[0].lastLabel == "Last AED 49.00")
        #expect(rows.map(\.priceChange) == [AnalysisChip("+9%", .warn), nil, nil, AnalysisChip("−17%", .positive)])
        #expect(rows.map(\.isOverdue) == [false, true, false, false])
        #expect(rows.map(\.whenLabel) == ["Next 2 Nov", "Expected 5 Oct, not seen yet", "Last charged 10 Oct",
                                          "Last charged 14 Jan"])
        #expect(rows[0].annualLabel == "AED 540 a year")
    }

    @Test("price-change badge: under half a percent is noise")
    func priceChange() {
        #expect(SubscriptionList.priceChangeBadge(nil) == nil)
        #expect(SubscriptionList.priceChangeBadge(dec("0.0049")) == nil)
        #expect(SubscriptionList.priceChangeBadge(dec("0.005")) == AnalysisChip("+1%", .warn))
        #expect(SubscriptionList.priceChangeBadge(dec("-0.12")) == AnalysisChip("−12%", .positive))
        #expect(SubscriptionList.cadenceLabel("fortnightly") == nil)
    }

    @Test("only active charges: no 'ended' clause; none: the empty state")
    func headlines() throws {
        let charges = try LedgerJSON.decode([RecurringCharge].self, from: try fixture("recurring_list"))
        #expect(SubscriptionList(Array(charges.prefix(1)), today: day(10, 14)).headline == "1 active charge")
        #expect(SubscriptionList([]).isEmpty)
    }
}

@Suite("Analysis (PAR-12) — loaders")
@MainActor
struct AnalysisLoaderTests {
    @Test("the calendar asks daily_spend only up to today, and keeps the range")
    func calendarRange() async {
        let api = StubAPI()
        api.dailyRows = [DailySpend(day: day(10, 1), amount: 50, txnCount: 1)]
        let screens = AnalysisScreens(api: api, today: { day(10, 3) })
        let loader = screens.calendar()
        await loader.load(profileCode: "prf_x", request: AnalysisRange(from: day(9, 1), to: day(10, 31)))
        #expect(api.analysisCalls == ["daily_spend 2026-09-01 2026-10-03"])
        #expect(loader.state.value?.to == day(10, 3))
        #expect(loader.state.value?.activeDays == 1)
        // The same request again is already on screen.
        await loader.loadIfNeeded(profileCode: "prf_x", request: AnalysisRange(from: day(9, 1), to: day(10, 31)))
        #expect(api.analysisCalls.count == 1)
        // A range wholly in the future asks for nothing.
        await loader.load(profileCode: "prf_x", request: AnalysisRange(from: day(11, 1), to: day(11, 30)))
        #expect(api.analysisCalls.count == 1)
        #expect(loader.state.value?.isEmpty == true)
    }

    @Test("each loader calls its RPC with the screen's range or year")
    func calls() async {
        let api = StubAPI()
        let screens = AnalysisScreens(api: api, today: { day(10, 14) })
        let range = AnalysisRange(from: day(5, 1), to: day(10, 14))
        await screens.hours().load(profileCode: "prf_x", request: range)
        await screens.foreignSpend().load(profileCode: "prf_x", request: range)
        await screens.yearOverYear().load(profileCode: "prf_x", request: 2025)
        #expect(api.analysisCalls == ["hour_weekday_pattern 2026-05-01 2026-10-14", "fx_spend 2026-05-01 2026-10-14",
                                      "yoy_compare 2025"])
        #expect(screens.currentYear == 2026)
    }

    @Test("a failure shows the error, and a retry that succeeds replaces it")
    func failure() async {
        let api = StubAPI()
        api.analysisError = .network("-1009")
        let loader = AnalysisScreens(api: api, today: { day(10, 14) }).foreignSpend()
        let range = AnalysisRange(from: day(10, 1), to: day(10, 14))
        await loader.load(profileCode: "prf_x", request: range)
        #expect(loader.state.errorMessage == "No connection to Ledger.")
        api.analysisError = nil
        api.fxRows = [FxSpend(currency: "USD", amountOriginal: 10, amountAed: dec("36.73"), txnCount: 1,
                              impliedRate: dec("3.673"), estimatedShare: 0)]
        await loader.loadIfNeeded(profileCode: "prf_x", request: range)
        #expect(loader.state.errorMessage == nil)
        #expect(loader.state.value?.map(\.currency) == ["USD"])
    }
}

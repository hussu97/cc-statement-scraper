import Foundation
import Testing
@testable import LedgerKit

private let today = CalendarDay(year: 2026, month: 10, day: 14)   // a Wednesday

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

private func point(_ bucket: String, _ key: String?, _ label: String, _ amount: String, count: Int = 1,
                   token: String? = nil) -> SpendPoint {
    SpendPoint(bucket: day(bucket), groupKey: key, groupLabel: label, colorToken: token,
               amount: Decimal(string: amount)!, txnCount: count)
}

@Suite("Trends: ranges, bucket sizes and labels (PAR-10)")
struct TrendsRangeTests {
    @Test("presets are the web's, ending today at the latest")
    func presets() {
        func bounds(_ p: TrendsPreset) -> String {
            let r = TrendsRange.preset(p, today: today)
            return "\(r.from)…\(r.to)"
        }
        #expect(bounds(.thisMonth) == "2026-10-01…2026-10-14")
        #expect(bounds(.lastMonth) == "2026-09-01…2026-09-30")
        #expect(bounds(.last3Months) == "2026-08-01…2026-10-14")
        #expect(bounds(.last6Months) == "2026-05-01…2026-10-14")
        #expect(bounds(.yearToDate) == "2026-01-01…2026-10-14")
        #expect(bounds(.last12Months) == "2025-11-01…2026-10-14")
        #expect(TrendsRangeChoice.all.map(\.label).last == "Custom range")
    }

    @Test("custom dates: put in order, never past today, and a preset's dates count as it")
    func custom() {
        let swapped = TrendsRange.custom(from: day("2026-09-30"), to: day("2026-09-01"), today: today)
        #expect(swapped.from == day("2026-09-01"))
        #expect(swapped.to == day("2026-09-30"))
        #expect(swapped.preset == .lastMonth)
        let future = TrendsRange.custom(from: day("2026-10-10"), to: day("2026-12-31"), today: today)
        #expect(future.to == today)
        #expect(future.preset == nil)
    }

    @Test("bucket sizes: no more than 93 bars; month always; the web's default by length")
    func grains() {
        let month = TrendsRange.preset(.thisMonth, today: today)
        #expect(month.grains == [.month, .week, .day])
        #expect(month.defaultGrain == .day)
        let quarter = TrendsRange.preset(.last3Months, today: today)       // 75 days
        #expect(quarter.grains == [.month, .week, .day])
        #expect(quarter.defaultGrain == .week)
        let half = TrendsRange.preset(.last6Months, today: today)          // 167 days
        #expect(half.grains == [.month, .week])
        #expect(half.defaultGrain == .month)
        #expect(half.grain(choosing: .day) == .month)                      // not offered: the default
        #expect(half.grain(choosing: .week) == .week)
        let years = TrendsRange.custom(from: day("2023-01-01"), to: today, today: today)
        #expect(years.grains == [.month])
        #expect(years.bucketCount(.month) == 46)
    }

    @Test("buckets start on the 1st, the Monday (date_trunc('week')) or the day")
    func buckets() {
        #expect(SpendGrain.week.bucketStart(of: today) == day("2026-10-12"))
        #expect(SpendGrain.week.bucketStart(of: day("2026-10-12")) == day("2026-10-12"))
        #expect(SpendGrain.week.bucketStart(of: day("2026-10-18")) == day("2026-10-12"))   // Sunday
        #expect(SpendGrain.week.bucketEnd(startingAt: day("2026-10-12")) == day("2026-10-18"))
        #expect(SpendGrain.month.bucketEnd(startingAt: day("2026-02-01")) == day("2026-02-28"))
        let r = TrendsRange.preset(.thisMonth, today: today)
        #expect(r.buckets(.week).map(\.iso) == ["2026-09-28", "2026-10-05", "2026-10-12"])
        #expect(r.buckets(.day).count == 14)
        #expect(r.bucketCount(.week) == 3)
    }

    @Test("labels pin en_US_POSIX and Dubai")
    func labels() {
        #expect(SpendGrain.month.axisLabel(today) == "Oct")
        #expect(SpendGrain.month.axisLabel(day("2025-10-01"), withYear: true) == "Oct 25")
        #expect(SpendGrain.week.axisLabel(day("2026-10-12")) == "12 Oct")
        #expect(SpendGrain.month.title(today) == "October 2026")
        #expect(SpendGrain.week.title(day("2026-10-12")) == "Week of 12 Oct 2026")
        #expect(SpendGrain.day.title(today) == "Wed 14 Oct 2026")
        #expect(SpendGrain.week.tableTitle == "By week")
        #expect(TrendsRange.preset(.last6Months, today: today).label == "1 May – 14 Oct 2026")
        #expect(TrendsRange.preset(.last12Months, today: today).label == "1 Nov 2025 – 14 Oct 2026")
        #expect(TrendsRange.custom(from: today, to: today, today: today).label == "14 Oct 2026")
    }
}

@Suite("Trends: shaping the server's series (PAR-10)")
struct TrendsSeriesTests {
    let range = TrendsRange.preset(.thisMonth, today: today)

    @Test("every bucket of the range is on the axis; totals are the server's, gaps have none")
    func totals() {
        let s = TrendsSeries(range: range, grain: .week, group: .total,
                             totals: [point("2026-09-28", nil, "Total", "120.75", count: 3),
                                      point("2026-10-12", nil, "Total", "80.00", count: 2)],
                             grouped: [])
        #expect(s.buckets.map(\.id) == ["2026-09-28", "2026-10-05", "2026-10-12"])
        #expect(s.buckets.map(\.total) == [Decimal(string: "120.75"), nil, Decimal(string: "80.00")])
        #expect(s.spentBuckets.map(\.id) == ["2026-10-12", "2026-09-28"])
        #expect(s.groups.isEmpty)
        #expect(!s.isGrouped)
        #expect(!s.isEmpty)
        #expect(s.accessibility.summary == "Highest week: Week of 28 Sep 2026, AED 121.")
        let none = TrendsSeries(range: range, grain: .week, group: .total, totals: [], grouped: [])
        #expect(none.isEmpty)
    }

    @Test("groups: largest first, Other last; categories keep their colour, others take the palette by rank")
    func groups() {
        let grouped = [
            point("2026-10-05", "cat_a", "Dining", "40.00", token: "cat-7"),
            point("2026-10-05", nil, "Other", "5.00"),
            point("2026-10-05", nil, "Uncategorised", "60.00"),
            point("2026-10-12", "cat_a", "Dining", "30.00", token: "cat-7"),
        ]
        let totals = [point("2026-10-05", nil, "Total", "105.00"), point("2026-10-12", nil, "Total", "30.00")]
        let cat = TrendsSeries(range: range, grain: .week, group: .category, totals: totals, grouped: grouped)
        #expect(cat.groups.map(\.label) == ["Dining", "Uncategorised", "Other"])
        #expect(cat.groups.map(\.key) == ["cat_a", "label:Uncategorised", "__other__"])
        #expect(cat.groups.map(\.colorToken) == ["cat-7", nil, "other"])
        let oct5 = cat.bucket(id: "2026-10-05")!
        #expect(oct5.total == Decimal(string: "105.00"))
        #expect(oct5.entries.map(\.groupKey) == ["cat_a", "label:Uncategorised", "__other__"])
        #expect(cat.segments.count == 4)

        let cards = TrendsSeries(range: range, grain: .week, group: .card, totals: totals, grouped: [
            point("2026-10-05", "crd_b", "FAB •1111", "10.00"),
            point("2026-10-05", "crd_a", "ADCB •2222", "95.00"),
        ])
        #expect(cards.groups.map(\.code) == ["crd_a", "crd_b"])
        #expect(cards.groups.map(\.colorToken) == ["cat-1", "cat-2"])
    }

    @Test("Bank: spend_breakdown's months, server totals and shares; an all-zero month has no total")
    func bank() throws {
        let b = try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))
        let r = TrendsRange.custom(from: day("2026-08-01"), to: today, today: today)
        let s = TrendsSeries(range: r, breakdown: b)
        #expect(s.grain == .month)
        #expect(s.buckets.map(\.label) == ["Aug", "Sep", "Oct"])
        #expect(s.buckets.map(\.total) == [Decimal(string: "1000.00"), nil, Decimal(string: "2500.00")])
        #expect(s.groups.map(\.key) == ["FAB", "ADCB", "__other__"])
        #expect(s.groups.map(\.colorToken) == ["cat-1", "cat-2", "other"])
        #expect(s.groups[0].share == Decimal(string: "0.5714"))
        #expect(s.bucket(id: "2026-10-01")!.entries.map(\.groupKey) == ["FAB", "ADCB", "__other__"])
    }

    @Test("month labels carry the year when a name repeats")
    func monthYears() {
        let r = TrendsRange.preset(.last12Months, today: today)
        let longer = TrendsRange.custom(from: day("2025-10-01"), to: today, today: today)
        let a = TrendsSeries(range: r, grain: .month, group: .total, totals: [], grouped: [])
        let b = TrendsSeries(range: longer, grain: .month, group: .total, totals: [], grouped: [])
        #expect(a.buckets.first?.label == "Nov")
        #expect(b.buckets.first?.label == "Oct 25")
        #expect(b.buckets.last?.label == "Oct 26")
    }

    @Test("crowded axes print every Nth label, from the first")
    func axis() {
        let r = TrendsRange.preset(.last3Months, today: today)
        let s = TrendsSeries(range: r, grain: .day, group: .total, totals: [], grouped: [])
        #expect(s.buckets.count == 75)
        let ids = s.axisBucketIDs(maxLabels: 6)
        #expect(ids.count <= 6)
        #expect(ids.first == "2026-08-01")
        #expect(TrendsSeries(range: range, grain: .week, group: .total, totals: [], grouped: []).axisBucketIDs(maxLabels: 6).count == 3)
    }
}

@Suite("Trends: links into Activity (PAR-10)")
struct TrendsActivityLinkTests {
    let range = TrendsRange.preset(.thisMonth, today: today)

    func series(_ group: TrendsGroup, _ rows: [SpendPoint]) -> TrendsSeries {
        TrendsSeries(range: range, grain: .week, group: group, totals: [point("2026-09-28", nil, "Total", "1.00")],
                     grouped: rows)
    }

    @Test("a bucket opens its days, clipped to the range")
    func bucket() throws {
        let s = series(.total, [])
        let q = try #require(s.activityQuery(bucket: s.buckets[0], group: nil, filter: SpendFilter()))
        #expect(q.from == day("2026-10-01"))     // the week starts 28 Sep; the range on 1 Oct
        #expect(q.to == day("2026-10-04"))
        #expect(q.filterCount == 1)
    }

    @Test("a slice adds its category, account, card or merchant; banks and Other have no link")
    func slices() throws {
        let cat = series(.category, [point("2026-09-28", "cat_a", "Dining", "1.00"), point("2026-09-28", nil, "Uncategorised", "1.00")])
        #expect(cat.activityQuery(bucket: cat.buckets[0], group: cat.groups[0], filter: SpendFilter())?.categoryCode == "cat_a")
        #expect(cat.activityQuery(bucket: cat.buckets[0], group: cat.groups[1], filter: SpendFilter())?.uncategorizedOnly == true)

        let acc = series(.account, [point("2026-09-28", "acc_a", "FAB", "1.00")])
        #expect(acc.activityQuery(bucket: acc.buckets[0], group: acc.groups[0], filter: SpendFilter())?.accountCode == "acc_a")
        let card = series(.card, [point("2026-09-28", "crd_a", "FAB •1111", "1.00")])
        #expect(card.activityQuery(bucket: card.buckets[0], group: card.groups[0], filter: SpendFilter())?.cardCode == "crd_a")
        let mer = series(.merchant, [point("2026-09-28", "mer_a", "Careem", "1.00"), point("2026-09-28", nil, "Other", "1.00")])
        #expect(mer.activityQuery(bucket: mer.buckets[0], group: mer.groups[0], filter: SpendFilter())?.search == "Careem")
        #expect(mer.activityQuery(bucket: mer.buckets[0], group: mer.groups[1], filter: SpendFilter()) == nil)

        let b = try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))
        let bank = TrendsSeries(range: range, breakdown: b)
        #expect(bank.activityQuery(bucket: bank.buckets[0], group: bank.groups[0], filter: SpendFilter()) == nil)
    }

    @Test("links use the filter the series was fetched with, not a newer one on screen")
    func seriesFilter() {
        var s = series(.total, [])
        s.filter = SpendFilter(categoryCodes: ["cat_a"])
        #expect(s.activityQuery(bucket: s.buckets[0], group: nil)?.categoryCode == "cat_a")
        s.filter = SpendFilter()
        #expect(s.activityQuery(bucket: s.buckets[0], group: nil)?.categoryCode == nil)
    }

    @Test("the filter carries over when Activity can show it, else there is no link")
    func filters() {
        let s = series(.total, [])
        let bucket = s.buckets[0]
        #expect(s.activityQuery(bucket: bucket, group: nil, filter: SpendFilter(categoryCodes: ["cat_a"]))?.categoryCode == "cat_a")
        #expect(s.activityQuery(bucket: bucket, group: nil, filter: SpendFilter(categoryCodes: [SpendFilter.uncategorized]))?
            .uncategorizedOnly == true)
        #expect(s.activityQuery(bucket: bucket, group: nil, filter: SpendFilter(cardCodes: ["crd_a"]))?.cardCode == "crd_a")
        #expect(s.activityQuery(bucket: bucket, group: nil, filter: SpendFilter(search: " uber "))?.search == "uber")
        #expect(s.activityQuery(bucket: bucket, group: nil, filter: SpendFilter(categoryCodes: ["cat_a", "cat_b"])) == nil)
        #expect(s.activityQuery(bucket: bucket, group: nil, filter: SpendFilter(bankCodes: ["FAB"])) == nil)

        let mer = series(.merchant, [point("2026-09-28", "mer_a", "Careem", "1.00")])
        #expect(mer.activityQuery(bucket: mer.buckets[0], group: mer.groups[0], filter: SpendFilter(search: "uber")) == nil)
        let cat = series(.category, [point("2026-09-28", "cat_a", "Dining", "1.00")])
        let q = cat.activityQuery(bucket: cat.buckets[0], group: cat.groups[0], filter: SpendFilter(categoryCodes: ["cat_a"]))
        #expect(q?.categoryCode == "cat_a")
        #expect(q?.uncategorizedOnly == false)
    }
}

@Suite("Trends: the model (PAR-10)")
@MainActor
struct TrendsModelTests {
    let profile = "prf_01hzy3k8w9m2n4p6q8r0s2t4v6"

    func model(_ api: StubAPI) -> TrendsModel { TrendsModel(api: api, today: { today }) }

    @Test("a grouping asks spend_series for the totals and the top 8 groups, over the filter")
    func grouped() async throws {
        let api = StubAPI()
        api.seriesByGroup = [.none: [point("2026-10-01", nil, "Total", "50.00")],
                             .account: [point("2026-10-01", "acc_a", "FAB", "50.00")]]
        let m = model(api)
        m.group = .account
        m.filter = SpendFilter(categoryCodes: ["cat_a"])
        await m.load(profileCode: profile)
        let requests = api.seriesRequests
        #expect(requests.map(\.group) == [.none, .account] || requests.map(\.group) == [.account, .none])
        #expect(Set(requests.map(\.top)) == [nil, 8])
        #expect(requests.allSatisfy { $0.grain == .month && $0.from == day("2026-05-01") && $0.to == today })
        #expect(api.seriesFilters.allSatisfy { $0.categoryCodes == ["cat_a"] })
        let s = try #require(m.state.value)
        #expect(s.groups.map(\.code) == ["acc_a"])
        #expect(s.bucket(id: "2026-10-01")?.total == Decimal(string: "50.00"))

        // Already on screen: no new request; forced: reloads.
        await m.load(profileCode: profile)
        #expect(api.seriesRequests.count == 2)
        await m.load(profileCode: profile, force: true)
        #expect(api.seriesRequests.count == 4)
    }

    @Test("Total asks once; Bank asks spend_breakdown and is monthly only")
    func totalAndBank() async throws {
        let api = StubAPI()
        api.breakdownByGroup = [.bank: try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))]
        let m = model(api)
        m.rangeChoice = .preset(.thisMonth)
        #expect(m.grain == .day)
        m.group = .total
        await m.load(profileCode: profile)
        #expect(api.seriesRequests.map(\.group) == [.none])
        #expect(api.seriesRequests.first?.grain == .day)

        m.group = .bank
        #expect(m.grain == .month)
        #expect(m.grainOptions == [.month])
        await m.load(profileCode: profile)
        #expect(api.breakdownRequests.map(\.0) == [.bank])
        #expect(api.breakdownRequests.first?.3 == SpendSplitModel.topN)
        #expect(m.state.value?.group == .bank)
    }

    @Test("a chosen bucket size holds while the range offers it, and comes back")
    func grainFollowsRange() {
        let m = model(StubAPI())
        #expect(m.grain == .month)                    // 6 months
        #expect(m.grainOptions == [.month, .week])
        m.grain = .week
        m.rangeChoice = .preset(.last12Months)        // 53 weeks: still offered
        #expect(m.grain == .week)
        m.rangeChoice = .custom
        m.customFrom = day("2023-01-01")              // too many weeks: months
        #expect(m.grain == .month)
        #expect(m.rangeChoice == .custom)
        m.customFrom = day("2026-09-01")
        #expect(m.grain == .week)
        m.customTo = day("2026-08-01")                // before From: the range follows
        #expect(m.range.from == day("2026-08-01"))
        #expect(m.range.to == day("2026-08-01"))
    }

    @Test("a failure keeps the chart on screen; another ledger clears the filter")
    func failureAndLedgerSwitch() async {
        let api = StubAPI()
        api.seriesPoints = [point("2026-10-01", nil, "Total", "50.00")]
        let m = model(api)
        m.group = .total
        m.filter = SpendFilter(search: "uber")
        await m.load(profileCode: profile)
        api.seriesError = .network("offline")
        await m.load(profileCode: profile, force: true)
        #expect(m.state.errorMessage != nil)
        #expect(m.state.value != nil)

        api.seriesError = nil
        await m.load(profileCode: "prf_01hzy3k8w9m2n4p6q8r0s2t4zz")
        #expect(m.filter.isEmpty)
        #expect(m.emptyMessage.hasPrefix("No spending in this range"))
    }

    @Test("selecting a bucket toggles; a new grouping clears it")
    func selection() async {
        let api = StubAPI()
        api.seriesPoints = [point("2026-10-01", nil, "Total", "50.00")]
        let m = model(api)
        await m.load(profileCode: profile)
        m.toggleBucket("2026-10-01")
        #expect(m.selected?.title == "October 2026")
        m.toggleBucket("2026-10-01")
        #expect(m.selected == nil)
        m.toggleBucket("2026-10-01")
        m.group = .card
        #expect(m.selectedBucket == nil)
    }
}

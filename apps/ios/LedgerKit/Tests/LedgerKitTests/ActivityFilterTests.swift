import Foundation
import Supabase
import Testing
@testable import LedgerKit

/// PAR-1: the Activity filters the web has (dates, card, void, source), sent to
/// `v_transactions`, `activity_summary` and `activity_day_totals` as the web sends them.
@Suite("Activity filters: presets, custom range, card, void, source (PAR-1)")
struct ActivityFilterTests {
    let today = CalendarDay(year: 2026, month: 10, day: 8)

    func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

    @Test("presets build the web's ranges (lib/dates.ts presetRange)")
    func presets() {
        #expect(ActivityDatePreset.thisMonth.range(today: today) == (day("2026-10-01"), day("2026-10-31")))
        #expect(ActivityDatePreset.lastMonth.range(today: today) == (day("2026-09-01"), day("2026-09-30")))
        #expect(ActivityDatePreset.last3Months.range(today: today) == (day("2026-08-01"), day("2026-10-31")))
        #expect(ActivityDatePreset.yearToDate.range(today: today) == (day("2026-01-01"), day("2026-10-08")))
        // January: last month is in the previous year.
        let jan = day("2027-01-15")
        #expect(ActivityDatePreset.lastMonth.range(today: jan) == (day("2026-12-01"), day("2026-12-31")))
        #expect(ActivityDatePreset.last3Months.range(today: jan) == (day("2026-11-01"), day("2027-01-31")))
    }

    @Test("a range reads back as its preset, else custom; Any time clears it")
    func dateChoice() {
        var q = ActivityQuery()
        #expect(q.dateChoice(today: today) == .any && q.dateLabel(today: today) == nil)
        q.choose(.preset(.lastMonth), today: today)
        #expect(q.from == day("2026-09-01") && q.to == day("2026-09-30"))
        #expect(q.dateChoice(today: today) == .preset(.lastMonth) && q.dateLabel(today: today) == "Last month")
        q.setRange(from: day("2026-09-01"), to: day("2026-09-15"))
        #expect(q.dateChoice(today: today) == .custom)
        #expect(q.dateLabel(today: today) == "1 Sep 2026 – 15 Sep 2026")
        q.choose(.custom, today: today)                       // keeps the range already set
        #expect(q.from == day("2026-09-01") && q.to == day("2026-09-15"))
        q.choose(.any, today: today)
        #expect(q.from == nil && q.to == nil && !q.hasFilters)
        q.choose(.custom, today: today)                       // starts at this month so far
        #expect(q.from == day("2026-10-01") && q.to == today)
    }

    @Test("a reversed custom range swaps its ends")
    func reversedRange() {
        var q = ActivityQuery()
        q.setRange(from: day("2026-10-05"), to: day("2026-09-01"))
        #expect(q.from == day("2026-09-01") && q.to == day("2026-10-05"))
        q.setRange(from: nil, to: day("2026-09-01"))
        #expect(q.from == nil && q.dateLabel(today: today) == "Until 1 Sep 2026")
    }

    @Test("a new account drops the card filter; the card list follows the account")
    func cardFollowsAccount() throws {
        let json = #"""
        {"accounts": [], "categories": [], "banks": [], "date_range": null, "cards": [
          {"card_code": "crd_1", "account_code": "acc_1", "bank_code": "FAB", "last4": "1234", "is_supplementary": false},
          {"card_code": "crd_2", "account_code": "acc_2", "bank_code": "EIB", "last4": "9216", "is_supplementary": true}]}
        """#
        let meta = try LedgerJSON.decode(FilterMeta.self, from: Data(json.utf8))
        #expect(meta.cards(forAccount: nil).map(\.cardCode) == ["crd_1", "crd_2"])
        #expect(meta.cards(forAccount: "acc_2").map(\.label) == ["EIB •9216 (supp.)"])
        var q = ActivityQuery()
        q.cardCode = "crd_1"
        q.setAccount(nil)
        #expect(q.cardCode == "crd_1")                        // unchanged account keeps the card
        q.setAccount("acc_2")
        #expect(q.accountCode == "acc_2" && q.cardCode == nil)
    }

    @Test("v_transactions filters match the web's applyActivityFilters, source included")
    func restFilters() {
        var q = ActivityQuery()
        // Spending's Activity (Wealth mode): always scoped, first.
        #expect(q.restFilters == [.isTrue("in_spending")])
        q.setRange(from: day("2026-09-01"), to: day("2026-09-30"))
        q.accountCode = "acc_1"
        q.cardCode = "crd_1"
        q.categoryCode = "cat_food"
        q.status = .void
        q.source = .sms
        q.search = "noon"
        #expect(q.restFilters == [
            .isTrue("in_spending"), .gte("txn_date", "2026-09-01"), .lte("txn_date", "2026-09-30"), .eq("account_code", "acc_1"),
            .eq("card_code", "crd_1"), .eq("category_code", "cat_food"), .eq("status", "void"),
            .isTrue("has_sms"), .isFalse("has_statement"),
            .or("description.ilike.*noon*,merchant_name.ilike.*noon*"),
        ])
        q = ActivityQuery()
        q.uncategorizedOnly = true
        q.categoryCode = "cat_food"
        q.source = .statement
        #expect(q.restFilters == [.isTrue("in_spending"), .isNull("category_code"), .isTrue("has_statement"),
                                  .isFalse("has_sms")])
        q.source = .both
        #expect(q.restFilters.suffix(2) == [.isTrue("has_sms"), .isTrue("has_statement")])
    }

    @Test("activity_summary gets the card and the source")
    func summaryParams() {
        var q = ActivityQuery()
        q.cardCode = "crd_1"
        q.source = .both
        q.status = .void
        let p = q.summaryParams(profileCode: "prf_a")
        #expect(p["p_card_code"] == .string("crd_1") && p["p_source"] == .string("both"))
        #expect(p["p_status"] == .string("void"))
    }

    @Test("the day-totals filter is the web's activityFilter object: set keys only, 'none' for uncategorised")
    func activityFilter() {
        var q = ActivityQuery()
        q.search = "   "
        #expect(q.activityFilter == ["scope": "spending"])
        q.setRange(from: day("2026-09-01"), to: day("2026-09-30"))
        q.accountCode = "acc_1"
        q.cardCode = "crd_1"
        q.uncategorizedOnly = true
        q.categoryCode = "cat_ignored"
        q.status = .void
        q.source = .statement
        q.search = "  café  "
        #expect(q.activityFilter == [
            "scope": "spending", "from": "2026-09-01", "to": "2026-09-30", "account": "acc_1", "card": "crd_1", "category": "none",
            "status": "void", "source": "statement", "q": "café",
        ])
    }

    @Test("every filter counts once toward 'Filters, N active'; Clear keeps the search")
    func filterCount() {
        var q = ActivityQuery()
        q.search = "noon"
        #expect(q.filterCount == 0 && !q.hasFilters)
        q.setRange(from: day("2026-09-01"), to: day("2026-09-30"))
        q.cardCode = "crd_1"
        q.source = .sms
        q.status = .void
        q.uncategorizedOnly = true
        #expect(q.filterCount == 5)
        q.clearFilters()
        #expect(q.filterCount == 0 && q.search == "noon" && q.source == .all && q.cardCode == nil)
    }

    @Test("void is a status choice, pending never is (SMS charges aren't set apart), and every choice has words")
    func statusAndSourceLabels() {
        #expect(ActivityQuery.StatusFilter.allCases.map(\.rawValue) == ["all", "void", "orphaned"])
        #expect(ActivityQuery.StatusFilter(rawValue: "pending") == nil)
        #expect(ActivityQuery.StatusFilter.void.label == "Void" && ActivityQuery.StatusFilter.all.label == "Any status")
        #expect(ActivityQuery.SourceFilter.allCases.map(\.label) == ["Any source", "SMS only", "Statement only", "SMS + statement"])
        #expect(ActivityDateChoice.all.map(\.label)
                == ["Any time", "This month", "Last month", "Last 3 months", "This year", "Custom range"])
    }
}

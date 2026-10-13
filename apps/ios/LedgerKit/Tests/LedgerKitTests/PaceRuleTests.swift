import Foundation
import Testing
@testable import LedgerKit

@Suite("Overview pace rule (PAR-6): server figures placed and worded, current month only")
struct PaceRuleTests {
    private func overview(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Overview {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("overview")) as? [String: Any])
        edit(&object)
        return try LedgerJSON.decode(Overview.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("pins: last month and the 3-month average by today, and the projection to the month's last day")
    func pins() throws {
        let o = try overview { $0["spend"] = "2000.00" }
        let rule = try #require(o.paceRule(today: CalendarDay(iso: "2026-10-13")!))
        #expect(rule.pins.map(\.label) == ["Last month by the 13th", "3-month average by the 13th"])
        #expect(rule.pins.map(\.amountLabel) == ["AED 2,100", "AED 2,650"])
        #expect(rule.projection == "Projected AED 9,100 by 31 Oct")
        #expect(rule.spendLabel == "AED 2,000 so far")
        // The largest value (the average, 2,650.40) sits 8% short of the end.
        let avgAt = try #require(rule.pins[1].at)
        #expect(abs(avgAt - 1 / 1.08) < 0.0001)
        let spendAt = try #require(rule.spendAt)
        #expect(abs(spendAt - 2000 / (2650.40 * 1.08)) < 0.0001)
        #expect(rule.accessibilityLabel
                == "Spent AED 2,000 so far; Last month by the 13th AED 2,100; 3-month average by the 13th AED 2,650. Projected AED 9,100 by 31 Oct.")
    }

    @Test("a past month has no pace rule")
    func pastMonth() throws {
        #expect(try overview().paceRule(today: CalendarDay(iso: "2026-11-02")!) == nil)
    }

    @Test("an older server: the whole-month average, labelled so, and no projection")
    func olderServer() throws {
        let o = try overview {
            $0.removeValue(forKey: "spend_avg_3m_to_date")
            $0.removeValue(forKey: "projected_month_end")
        }
        let rule = try #require(o.paceRule(today: CalendarDay(iso: "2026-10-01")!))
        #expect(rule.pins[0].label == "Last month by the 1st")
        #expect(rule.pins[1].label == "3-month average, whole month" && rule.pins[1].amountLabel == "AED 9,000")
        #expect(rule.projection == nil)
    }

    @Test("nothing above zero: no positions, nothing drawn")
    func allZero() {
        #expect(PaceRule.positions([0, 0, 0]) == [nil, nil, nil])
        #expect(PaceRule.positions([-5, 10]) == [0, 10 / 10.8])
    }

    @Test("ordinals")
    func ordinals() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map(PaceRule.ordinal)
                == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"])
    }
}

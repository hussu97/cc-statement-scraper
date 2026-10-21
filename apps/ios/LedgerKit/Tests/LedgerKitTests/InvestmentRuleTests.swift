import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

@Suite("Investments: exact payment rules and why returns leave a holding out")
struct InvestmentRuleTests {
    let today = day("2026-10-21")

    func plan(rule: String, exact: Bool) -> HoldingDraft {
        var d = HoldingDraft(today: today, kind: .plan)
        d.name = "RL360"
        d.linkPattern = rule
        d.linkExact = exact
        return d
    }

    @Test("contains needs 3 characters; matching the whole description allows 2 and sends p_link_exact")
    func ruleLength() throws {
        #expect(plan(rule: "RI", exact: false).validate(today: today)
                == "A 2-character rule must match the whole description: switch on Match the whole description.")
        #expect(plan(rule: "R", exact: true).validate(today: today)
                == "An exact payment rule is 2 to 60 characters, e.g. RI, or leave it empty.")
        #expect(plan(rule: "R", exact: false).validate(today: today)?.hasPrefix("A payment rule is 3 to 60") == true)
        let exact = try #require(plan(rule: " RI ", exact: true).submission(today: today))
        #expect(exact.linkPattern == "RI" && exact.linkExact)
        let params = SupabaseLedgerAPI.saveHoldingParams(profileCode: "prf_a", holding: exact)
        #expect(params["p_link_exact"] == .bool(true) && params["p_link_pattern"] == .string("RI"))
        // No rule: exact is never sent on.
        let none = try #require(plan(rule: "", exact: true).submission(today: today))
        #expect(none.linkPattern == nil && !none.linkExact)
        #expect(plan(rule: "RL360", exact: false).submission(today: today)?.linkExact == false)
        #expect(plan(rule: "x", exact: true).linkRuleMinimum == 2 && plan(rule: "x", exact: false).linkRuleMinimum == 3)
        #expect(plan(rule: "RI", exact: true).linkRuleNote.hasPrefix("Payments whose whole description is exactly"))
    }

    @Test("the server's length check (23514) in words; an edit keeps the mode")
    func serverAndEdit() {
        #expect(HoldingDraft.message(for: LedgerAPIError.server(status: nil, code: "23514", message: "check"))
                == "Check the payment rule: it needs 3 characters, or 2 with Match the whole description on.")
        let h = Holding(holdingCode: "h", name: "RL360", kind: .plan, linkPattern: "RI", linkExact: true)
        #expect(HoldingDraft(holding: h, today: today).linkExact)
        #expect(h.linkRuleText == "Links payments described exactly “RI”")
        let contains = Holding(holdingCode: "h", name: "RL360", kind: .plan, linkPattern: "RL360")
        #expect(contains.linkRuleText == "Links payments containing “RL360”" && !contains.linkExact)
        #expect(Holding(holdingCode: "h", name: "P", kind: .plan).linkRuleText == nil)
    }

    @Test("holdings_valuation's link_exact decodes; absent reads as contains")
    func decode() throws {
        let json = #"{"holding_code": "h", "name": "RL360", "kind": "plan", "link_pattern": "RI", "link_exact": true}"#
        #expect(try LedgerJSON.decode(Holding.self, from: Data(json.utf8)).linkExact)
        #expect(try KindsFixtures.holding("RL360 plan").linkExact == false)
    }

    @Test("all time leaves out a holding with no money recorded going in; a period, one with no start value")
    func incompleteness() throws {
        let all = try KindsFixtures.returns("holding_returns_all_incomplete")
        #expect(!all.total.complete && all.incomplete.map(\.name) == ["Bangles"])
        #expect(all.incompleteNote == "Left out: Bangles has no money recorded going in, so the total covers the rest.")
        let ytd = try KindsFixtures.returns("holding_returns_ytd")
        #expect(ytd.incompleteNote?.contains("had no value on 1 Jan 2026") == true)
        #expect(HoldingReturn.incompleteNote(period: .all).hasPrefix("No money recorded going in"))
        #expect(HoldingReturn.incompleteNote(period: .twelveMonths).hasPrefix("No value at the start"))
        let two = HoldingReturns(period: .all, total: ReturnFigures(complete: false), holdings: [
            HoldingReturn(holdingCode: "a", name: "A", kind: .metal, figures: ReturnFigures(complete: false)),
            HoldingReturn(holdingCode: "b", name: "B", kind: .metal, figures: ReturnFigures(complete: false)),
        ])
        #expect(two.incompleteNote == "Left out: A and B have no money recorded going in, so the total covers the rest.")
    }
}

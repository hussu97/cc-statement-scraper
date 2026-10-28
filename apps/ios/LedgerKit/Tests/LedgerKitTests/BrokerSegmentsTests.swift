import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private func at(_ iso: String) -> Date { LedgerDates.parseTimestamp(iso)! }

/// `broker_portfolio` for a Zerodha account (`20261027202923_zerodha_sync.sql`): measured against
/// cost, split into Kite and Coin. The fixture is the RPC's real output for invented holdings.
@Suite("Broker portfolio against cost: Zerodha's Kite and Coin")
struct BrokerSegmentsTests {
    static func portfolio() throws -> BrokerPortfolio {
        try #require(try BrokerPortfolio.decode(try fixture("broker_portfolio_zerodha")))
    }

    static let now = at("2026-10-28T12:00:00+00:00")

    @Test("the wire: basis, invested, segments, each position's segment, each day's invested")
    func decodes() throws {
        let p = try Self.portfolio()
        #expect(p.provider == "zerodha" && p.currency == "INR" && p.basis == .cost)
        #expect(p.invested == dec("414899.39") && p.profit == dec("131947.38"))
        #expect(p.segments.map(\.segment) == ["kite", "coin"])
        #expect(p.segments[1].invested == dec("255526.39") && p.segments[1].returnPct == dec("40.90"))
        #expect(p.segments[0].positions == 3)
        #expect(Set(p.positions.compactMap(\.segment)) == ["kite", "coin"])
        #expect(p.series.map(\.invested) == [dec("414899.39"), dec("414899.39"), dec("414899.39")])
        #expect(p.closedTotal?.count == 1)
    }

    @Test("an older or other broker's payload reads as measured against deposits, with no segments")
    func olderPayload() throws {
        let json = #"{"account_code":"acc_1","total":"10.00","profit":"1.00","basis":"something-new"}"#
        let p = try #require(try BrokerPortfolio.decode(Data(json.utf8)))
        #expect(p.basis == .deposits && p.segments.isEmpty && p.invested == nil)
        let old = try BrokerPortfolioTests.portfolio()
        #expect(old.basis == .deposits && BrokerPortfolioPresentation(old).segmentGroups.isEmpty)
    }

    @Test("the three numbers say P&L on what was invested")
    func figures() throws {
        let view = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now)
        #expect(view.providerName == "Zerodha")
        #expect(view.figures.map(\.label) == ["Total value", "P&L", "Cash"])
        #expect(view.figures[1].value == "+INR 131,947")
        #expect(view.figures[1].sub == "on INR 414,899 invested")
        #expect(view.figures[1].tone == .positive)
        #expect(view.title(.pastNotes) == "Sold (1)")
    }

    @Test("Kite and Coin in a line each: invested, current, P&L with its return")
    func segmentLines() throws {
        let lines = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now).segments
        #expect(lines.map(\.title) == ["Kite", "Coin"])
        #expect(lines.map(\.subtitle) == ["Stocks and ETFs", "Mutual funds"])
        #expect(lines[0].investedText == "INR 159,373" && lines[0].valueText == "INR 186,820")
        #expect(lines[0].profitText == "+INR 27,447 (+17.2%)" && lines[0].profitTone == .positive)
        #expect(lines[1].accessibilityLabel.hasPrefix("Coin, Mutual funds: invested INR 255,526"))
    }

    @Test("Zerodha Kite or Coin alone: no segment line repeats the three numbers")
    func singleSegment() throws {
        #expect(BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now).segments.count == 2)
        let json = #"{"account_code":"acc_1","provider":"zerodha","currency":"INR","basis":"cost","total":"10.00","profit":"1.00","segments":[{"segment":"coin","positions":"1","invested":"9.00","value":"10.00","value_aed":"0.44","profit":"1.00","return_pct":"11.11"}]}"#
        let coin = try #require(try BrokerPortfolio.decode(Data(json.utf8)))
        #expect(coin.segments.count == 1)
        #expect(BrokerPortfolioPresentation(coin, now: Self.now).segments.isEmpty)
    }

    @Test("the Portfolio tab: a card per segment, Kite first, largest value first, each with units and cost")
    func groups() throws {
        let groups = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now).segmentGroups
        #expect(groups.map(\.segment) == ["kite", "coin"])
        #expect(groups.map(\.eyebrow) == ["KITE", "COIN"])
        #expect(groups[0].rows.map(\.title) == ["NIFTYBEES", "INFY", "RELIANCE"])
        let reliance = groups[0].rows[2]
        #expect(reliance.detailText == "15 units · invested INR 20,250")
        #expect(reliance.profitText == "−INR 3,222 (−15.9%)" && reliance.profitTone == .danger)
        #expect(groups[1].rows[1].detailText == "1,234.567 units · invested INR 75,598")
        #expect(!groups[0].rows[0].opensNote)
    }

    @Test("an unknown segment groups last as Other; the other holdings list never shows cost")
    func otherSegment() throws {
        #expect(BrokerSegmentText.label("fno") == "Other" && BrokerSegmentText.holds(nil) == "Other holdings")
        let view = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now)
        #expect(view.otherHoldings.allSatisfy { $0.detailText == nil })
    }

    @Test("the chart: the holdings' worth against what they cost, cash aside")
    func chart() throws {
        let chart = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now).chart
        #expect(chart.lineLabel == "Invested")
        #expect(chart.values.map(\.value) == [dec("547341.58"), dec("548848.51"), dec("546846.77")])
        #expect(chart.deposits.map(\.value) == [dec("414899.39"), dec("414899.39"), dec("414899.39")])
        #expect(chart.note == "The holdings' worth each day against what they cost.")
        #expect(chart.accessibilityValue.hasSuffix("against INR 414,899.39 invested"))
        // Another broker keeps its words.
        #expect(BrokerPortfolioPresentation(try BrokerPortfolioTests.portfolio()).chart.lineLabel == "Net deposits")
    }

    @Test("a Zerodha Kite or Coin account shows its loading and failure like Swissquote")
    func section() {
        #expect(BrokerSection(.loading(previous: nil), bankCode: "ZRD") == .loading)
        #expect(BrokerSection(.loading(previous: nil), bankCode: "KITE") == .loading)
        #expect(BrokerSection(.failed("Offline", previous: nil), bankCode: "COIN") == .failed("Offline"))
        #expect(BrokerSection(.loading(previous: nil), bankCode: "ENBD") == .hidden)
    }
}

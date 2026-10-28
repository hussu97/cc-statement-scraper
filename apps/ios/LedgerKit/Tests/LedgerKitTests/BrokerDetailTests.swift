import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private func at(_ iso: String) -> Date { LedgerDates.parseTimestamp(iso)! }

/// Zerodha Kite and Coin in detail (`20261028062806_zerodha_position_detail.sql`). The fixtures are
/// the RPCs' real output for invented holdings: Kite (two shares and an ETF), Coin (three funds,
/// a SIP whose October instalment was rejected and a paused one), and one fund's own page.
@Suite("Zerodha detail: today's move, allocation, highlights, SIPs, sortable holdings, a position")
struct BrokerDetailTests {
    static let now = at("2026-10-28T12:00:00+00:00")

    static func kite() throws -> BrokerPortfolioPresentation {
        BrokerPortfolioPresentation(try #require(try BrokerPortfolio.decode(try fixture("broker_portfolio_kite_detail"))), now: now)
    }

    static func coin() throws -> BrokerPortfolioPresentation {
        BrokerPortfolioPresentation(try #require(try BrokerPortfolio.decode(try fixture("broker_portfolio_coin_detail"))), now: now)
    }

    @Test("the wire: each position's class, prices and moves; the account's move, allocation, houses, SIPs")
    func decodes() throws {
        let k = try Self.kite().portfolio
        let paragmilk = try #require(k.positions.first { $0.symbol == "PHDAIRY" })
        #expect(paragmilk.detail.assetClass == "stock" && paragmilk.detail.exchange == "NSE")
        #expect(paragmilk.detail.prevPrice == dec("242.45") && paragmilk.detail.costPrice == dec("122.7736"))
        #expect(paragmilk.detail.dayChange == dec("-300.00") && paragmilk.detail.returnPct == dec("95.52"))
        #expect(k.detail.dayChange == dec("2.00"))
        let c = try Self.coin().portfolio
        #expect(c.detail.allocation.map(\.key) == ["fund:Equity", "fund:Debt"])
        #expect(c.detail.issuers.count == 3)
        #expect(c.detail.highlights?.best.count == 2 && c.detail.highlights?.top5WeightPct == nil)
        let sip = try #require(c.detail.sips.first { $0.missed })
        #expect(sip.stepUp == ["10-02": 3] && sip.lastOrder?.status == "rejected")
        #expect(sip.nextInstalment == CalendarDay(iso: "2026-11-05"))
    }

    @Test("an older payload reads as no detail")
    func olderPayload() throws {
        let json = #"{"account_code":"acc_1","total":"10.00","profit":"1.00","positions":[{"holding_code":"h","name":"X","currency":"INR"}]}"#
        let p = try #require(try BrokerPortfolio.decode(Data(json.utf8)))
        #expect(p.detail.dayChange == nil && p.detail.allocation.isEmpty && p.detail.highlights == nil && p.detail.sips.isEmpty)
        #expect(p.positions[0].detail == BrokerPositionFields())
    }

    @Test("figures: Today beside value and P&L; Coin's nil cash left out")
    func figures() throws {
        let k = try Self.kite()
        #expect(k.figures.map(\.label) == ["Total value", "P&L", "Today", "Cash"])
        #expect(k.figures[2].value == "+INR 2" && k.figures[2].tone == .positive)
        let c = try Self.coin()
        #expect(c.figures.map(\.label) == ["Total value", "P&L", "Today"])
        #expect(c.figures[2].value == "+INR 3,538" && c.figures[2].sub == "+1.01%")
        #expect(c.showsDetail && k.showsDetail)
    }

    @Test("holdings: sorted by the chosen column, unknowns last; the row shows the figure it is sorted by")
    func holdings() throws {
        let k = try Self.kite()
        #expect(k.holdingRows(sort: .value).map(\.title) == ["PLACEHOLDER FOODS", "TESTSHOP", "NIPPON INDIA ETF NIFTY BEES"])
        let today = k.holdingRows(sort: .today)
        #expect(today.map(\.title) == ["TESTSHOP", "PLACEHOLDER FOODS", "NIPPON INDIA ETF NIFTY BEES"])
        #expect(today[0].figureText == "+INR 302 (+1.07%) today" && today[0].figureTone == .positive)
        #expect(today[2].figureText == "No move yet today")
        #expect(k.holdingRows(sort: .name).map(\.title).first == "NIPPON INDIA ETF NIFTY BEES")
        let byValue = k.holdingRows(sort: .value)
        #expect(byValue[0].subtitle == "PHDAIRY · NSE · 125 units")
        #expect(byValue[2].subtitle == "ETF · NIFTYBEES · NSE · 94 units")
        #expect(byValue[0].figureText == "+INR 14,660 (+95.5%)")
        #expect(k.holdingRows(sort: .weight)[0].figureText.hasSuffix("of the account"))
    }

    @Test("allocation by scheme type, or by fund house")
    func allocation() throws {
        let c = try Self.coin()
        let types = c.allocation(byHouse: false)
        #expect(types.map(\.title) == ["Equity · 2", "Debt · 1"])
        #expect(types[0].weightText == "98.46%" && types[1].returnText == "−4.8%" && types[1].returnTone == .danger)
        #expect(abs(types[0].share - 0.9846) < 0.0001 && types.map(\.colorIndex) == [0, 1])
        #expect(c.hasFundHouses)
        #expect(c.allocation(byHouse: true).map(\.title).first == "Northwind Mutual Fund · 1")
        let k = try Self.kite()
        #expect(!k.hasFundHouses && k.allocation(byHouse: true).map(\.key) == ["stock", "etf"])
    }

    @Test("highlights: only lists with something; no top-five share with three positions")
    func highlights() throws {
        let c = try Self.coin()
        #expect(c.highlightSections.map(\.title) == ["Best since bought", "Worst since bought", "Up most today"])
        #expect(c.highlightSections[1].rows.first?.figureText == "−4.8%")
        #expect(c.highlightSections[2].rows.first?.figureText == "+INR 3,538 +1.01%")
        #expect(c.concentrationText == nil)
    }

    @Test("SIPs: schedule with step-up; a rejected instalment dated in India with its reason; paused")
    func sips() throws {
        let c = try Self.coin()
        let rows = c.sipRows
        #expect(rows.count == 2)
        #expect(rows[0].schedule == "INR 2,184 monthly, on the 5th · Steps up 3% every 2 Oct")
        // 20:20 UTC on 4 Oct is 5 Oct 01:50 in India: the instalment keeps India's date.
        #expect(rows[0].statusText == "The 5 Oct instalment was rejected: Payment not received")
        #expect(rows[0].statusTone == .danger && rows[0].badge == "Missed")
        #expect(rows[1].statusText == "Paused" && rows[1].badge == "Paused")
        #expect(c.missedSipsText == "1 instalment missed")
        #expect(BrokerDetailText.istDay(at("2026-09-30T20:11:05Z")) == CalendarDay(iso: "2026-10-01"))
        #expect(BrokerDetailText.stepUp(["04-10": 10]) == "Steps up 10% every 10 Apr")
        #expect(BrokerDetailText.stepUp(["junk": 3]) == nil && BrokerDetailText.stepUp(nil) == nil)
    }

    @Test("a position: what it is, four figures, the details, its worth against cost over time")
    func position() throws {
        let d = try #require(try BrokerPositionDetail.decode(try fixture("broker_position_detail")))
        let p = BrokerPositionPresentation(d, now: Self.now)
        #expect(p.title == "NORTHWIND SMALL CAP FUND - DIRECT PLAN" && p.kind == "Fund")
        #expect(p.subtitle == "Equity · Northwind Mutual Fund")
        #expect(p.figures.map(\.label) == ["Value", "P&L", "Today", "Share of account"])
        #expect(p.figures[0].sub == "INR 193.8273 NAV on 27 Oct")
        #expect(p.figures[1].sub == "+209.3% on INR 114,396 invested")
        #expect(p.figures[2].value == "+INR 3,538")
        #expect(p.facts.map(\.label) == ["Units", "Average cost", "NAV", "Previous NAV", "Scheme type", "Fund house", "Folio", "ISIN", "Last synced"])
        #expect(p.facts[1].value == "INR 62.6636")
        #expect(p.chart.values.count == 2 && p.chart.deposits.count == 2)
        #expect(p.chart.note == "Its worth each day against what it cost.")
        #expect(p.noLongerHeldText == nil)
        #expect(try BrokerPositionDetail.decode(Data("null".utf8)) == nil)
    }
}

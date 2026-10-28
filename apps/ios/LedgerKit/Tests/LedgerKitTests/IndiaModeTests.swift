import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private func indiaFixture() throws -> IndiaOverview { try LedgerJSON.decode(IndiaOverview.self, from: try fixture("india_overview")) }

@Suite("India mode: india_overview decodes")
struct IndiaOverviewDecodingTests {
    @Test("the contract's shape: exact decimals, 24h keys, counts as strings, series oldest first")
    func decodes() throws {
        let o = try indiaFixture()
        #expect(o.available && o.currency == "INR" && o.period == "90d")
        #expect(o.from == day("2026-07-30") && o.to == day("2026-10-28"))
        #expect(o.total.value == dec("1254310.55") && o.total.valueAed == dec("54321.40"))
        #expect(o.total.change24h == dec("-4210.50") && o.total.change24hAed == dec("-182.35"))
        #expect(o.total.change24hPct == dec("-0.34") && o.total.pnlPct == dec("12.17"))
        #expect(o.total.periodGrowth == dec("79310.55") && o.total.periodGrowthPct == dec("6.75"))
        #expect(o.total.positions == 12 && o.total.lastSyncedAt != nil)
        #expect(o.accounts.map(\.bankCode) == ["KITE", "COIN"])
        #expect(o.accounts[0].change24h == dec("1204.00") && o.accounts[0].positions == 8)
        #expect(o.accounts[1].cash == nil && o.accounts[1].change24h == nil && o.accounts[1].syncStatus == "error")
        #expect(o.series.map(\.date) == [day("2026-07-30"), day("2026-08-30"), day("2026-09-30"), day("2026-10-28")])
        #expect(o.series[1].value == nil && o.series[1].invested == dec("1050000.00"))
        #expect(o.tabs == [.overview, .kite, .coin])
        #expect(o.account(for: .coin)?.accountCode == "acc_01COIN00000000000000000000")
    }

    @Test("not available: India isn't offered; missing fields are nil, not a failed screen")
    func unavailable() throws {
        let o = try LedgerJSON.decode(IndiaOverview.self, from: Data(#"{"available": false, "total": {}}"#.utf8))
        #expect(!o.available && o.tabs.isEmpty && o.accounts.isEmpty && o.series.isEmpty)
        #expect(o.total.value == nil && o.total.positions == 0 && o.currency == "INR")
        let empty = try LedgerJSON.decode(IndiaOverview.self, from: Data("{}".utf8))
        #expect(!empty.available)
    }

    @Test("an account's tab: by segment, else by bank (ZRD is Kite's); an unknown one opens none")
    func tabs() throws {
        let json = #"""
        {"available": true, "accounts": [
          {"account_code": "a", "segment": "coin"},
          {"account_code": "b", "bank_code": "ZRD"},
          {"account_code": "c", "segment": "us_stocks", "bank_code": "XYZ"}
        ]}
        """#
        let o = try LedgerJSON.decode(IndiaOverview.self, from: Data(json.utf8))
        #expect(o.accounts.map(\.tab) == [.coin, .kite, nil])
        #expect(o.tabs == [.overview, .kite, .coin])
        let onlyCoin = IndiaOverview(available: true, accounts: [.init(accountCode: "a", bankCode: "COIN", name: "Zerodha Coin")])
        #expect(onlyCoin.tabs == [.overview, .coin])
        #expect(IndiaOverview(available: true).tabs == [.overview])
    }
}

@Suite("India mode: what the Overview says")
struct IndiaPresentationTests {
    let now = LedgerDates.parseTimestamp("2026-10-28T10:00:00Z")!

    @Test("the hero: rupees first, AED under, invested, P&L, cash and the last 24 hours")
    func hero() throws {
        let hero = IndiaHero(try indiaFixture(), now: now)
        #expect(hero.currency == "INR" && hero.amount == "1,254,311")
        #expect(hero.aedText == "≈ AED 54,321")
        #expect(hero.lines.map(\.label) == ["Invested", "P&L", "Cash", "Last 24 hours"])
        #expect(hero.lines.map(\.text) == ["INR 1,102,000", "+INR 134,060 (+12.17%)", "INR 18,250", "−INR 4,211 (−0.34%)"])
        #expect(hero.lines.map(\.tone) == [.neutral, .positive, .neutral, .danger])
        #expect(hero.syncText == "Synced today, 12:30")
        #expect(hero.accessibilityLabel == "India, all accounts, INR 1,254,311, ≈ AED 54,321")
    }

    @Test("a hero with nothing known yet shows only the value")
    func sparseHero() {
        let hero = IndiaHero(IndiaOverview(available: true, total: .init(value: 0)))
        #expect(hero.amount == "0" && hero.aedText == nil && hero.lines.isEmpty && hero.syncText == nil)
    }

    @Test("each account's row: value, AED, P&L and positions, the 24-hour move, a failed sync")
    func rows() throws {
        let rows = IndiaText.rows(try indiaFixture())
        #expect(rows.map(\.title) == ["Zerodha Kite", "Zerodha Coin"])
        #expect(rows[0].valueText == "INR 812,450" && rows[0].aedText == "≈ AED 35,184")
        #expect(rows[0].detail == "+INR 64,210 (+8.59%) · 8 positions" && rows[0].detailTone == .positive)
        #expect(rows[0].changeText == "+INR 1,204 (+0.29%) in 24h" && rows[0].changeTone == .positive)
        #expect(rows[0].tab == .kite && !rows[0].syncFailed)
        #expect(rows[1].detail == "+INR 69,850 (+19.74%) · 4 positions · last sync failed")
        #expect(rows[1].detailTone == .warn && rows[1].changeText == nil && rows[1].tab == .coin)
    }

    @Test("the period block: start, added, now, growth and return, as far as known")
    func period() throws {
        let o = try indiaFixture()
        let lines = IndiaPeriod.lines(o)
        #expect(lines.map(\.label) == ["Value at start", "Money added", "Value now", "Growth", "Return"])
        #expect(lines.map(\.text) == ["INR 1,080,000", "+INR 95,000", "INR 1,254,311", "+INR 79,311", "+6.75%"])
        #expect(IndiaPeriod.rangeText(o) == "Since 30 Jul 2026")
        #expect(IndiaPeriod.lines(IndiaOverview(available: true)).isEmpty)
        #expect(IndiaPeriod.note(o) == IndiaPeriod.growthNote)
        let late = IndiaOverview(available: true, from: day("2026-07-30"), total: .init(periodEndValue: dec("573077.83")))
        #expect(IndiaPeriod.lines(late).map(\.label) == ["Value now"])
        #expect(IndiaPeriod.note(late)
            == "No value on 30 Jul 2026, the period's first day, so no growth for it yet. A shorter period may have one.")
        #expect(IndiaChart.known(o.series).map(\.date) == [day("2026-07-30"), day("2026-09-30"), day("2026-10-28")])
    }

    @Test("a move under one rupee is no move")
    func flatChange() {
        #expect(IndiaText.change(dec("0.40"), dec("0.00"), currency: "INR") == nil)
        #expect(IndiaText.change(nil, nil, currency: "INR") == nil)
        #expect(IndiaText.change(dec("-12"), nil, currency: "INR") == "−INR 12")
    }
}

@Suite("India mode: the model")
@MainActor
struct IndiaModelTests {
    func stub(_ periods: [ReturnsPeriod]) throws -> StubAPI {
        let api = StubAPI()
        let o = try indiaFixture()
        api.indiaFixtures = Dictionary(uniqueKeysWithValues: periods.map { ($0, o) })
        return api
    }

    @Test("loads 90 days once, tells the router the tabs, and names each tab's account")
    func loads() async throws {
        let api = try stub([.ninetyDays, .ytd])
        let model = IndiaModel(api: api)
        var told: [[LedgerTab]] = []
        model.onLoaded = { tabs, code in
            #expect(code == "prf_a")
            told.append(tabs)
        }
        await model.loadIfNeeded(profileCode: "prf_a")
        await model.loadIfNeeded(profileCode: "prf_a")
        #expect(api.indiaCalls == [.ninetyDays])
        #expect(told == [[.overview, .kite, .coin]])
        #expect(model.selected.value?.available == true)
        #expect(model.account(for: .kite)?.name == "Zerodha Kite")

        await model.select(.ytd, profileCode: "prf_a")
        await model.select(.ninetyDays, profileCode: "prf_a")
        await model.select(.ytd, profileCode: "prf_a")
        #expect(api.indiaCalls == [.ninetyDays, .ytd])   // each period read once
        #expect(model.period == .ytd && model.selected.value != nil)

        model.reset()
        #expect(model.state.value == nil && model.period == .ninetyDays && model.periods.isEmpty)
    }

    @Test("no India account: told with no tabs")
    func unavailable() async {
        let model = IndiaModel(api: StubAPI())
        var told: [[LedgerTab]] = []
        model.onLoaded = { tabs, _ in told.append(tabs) }
        await model.load(profileCode: "prf_a")
        #expect(told == [[]] && model.state.value?.available == false)
    }

    @Test("a failed read says so, tells the router nothing, and is read again")
    func failed() async throws {
        let api = try stub([.ninetyDays, .thirtyDays])
        api.indiaError = .network("-1009")
        let model = IndiaModel(api: api)
        var told = 0
        model.onLoaded = { _, _ in told += 1 }
        await model.loadIfNeeded(profileCode: "prf_a")
        #expect(model.state.errorMessage != nil && told == 0)
        await model.select(.thirtyDays, profileCode: "prf_a")
        #expect(model.selected.errorMessage != nil)
        api.indiaError = nil
        await model.loadIfNeeded(profileCode: "prf_a")
        #expect(model.state.value?.available == true && told == 1)
        await model.select(.thirtyDays, profileCode: "prf_a")
        #expect(model.selected.value != nil)
    }
}

@Suite("India mode: the mode switch")
@MainActor
struct IndiaModeSwitchTests {
    @Test("India: Overview, Kite and Coin; its tabs are India's; the menu names every mode")
    func tabs() {
        #expect(AppMode.india.tabs == [.overview, .kite, .coin] && AppMode.india.title == "India")
        #expect(AppMode.home(of: .kite) == .india && AppMode.home(of: .coin) == .india)
        #expect(AppMode.offered(india: false) == [.spending, .wealth])
        #expect(AppMode.offered(india: true) == [.spending, .wealth, .india])
        #expect(AppMode.menuHint([.spending, .wealth]) == "Switches between Spending and Wealth")
        #expect(AppMode.menuHint([.spending, .wealth, .india]) == "Switches between Spending, Wealth and India")
        #expect(AppMode.restored("india") == .india)
        #expect(LedgerTab.kite.title == "Kite" && LedgerTab.coin.title == "Coin")
    }

    @Test("offered only once the ledger is known to have India; narrowed to its accounts")
    func offered() {
        let router = TabRouter()
        #expect(router.modes == [.spending, .wealth])
        router.indiaLoaded([.overview, .coin])
        #expect(router.modes == [.spending, .wealth, .india])
        router.switchMode(.india)
        #expect(router.shownTabs == [.overview, .coin])
        router.show(.coin)
        #expect(router.mode == .india && router.tab == .coin)
        router.indiaLoaded([.overview, .kite])   // Coin went away
        #expect(router.tab == .overview && router.shownTabs == [.overview, .kite])
        router.show(.activity)
        #expect(router.mode == .spending && router.tab == .activity)
        router.show(.kite)
        #expect(router.mode == .india && router.tab == .kite)
        router.indiaLoaded([])
        #expect(router.modes == [.spending, .wealth])
    }

    @Test("a remembered India falls back to Spending for a ledger without it, and comes back for one with it")
    func fallback() throws {
        let suite = "ledger-india-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("india", forKey: AppMode.defaultsKey)

        let router = TabRouter(defaults: defaults)
        #expect(router.mode == .india && router.modes.contains(.india))   // until the ledger answers
        #expect(router.shownTabs == [.overview, .kite, .coin])
        router.indiaLoaded([])
        #expect(router.mode == .spending && router.tab == .overview && !router.modes.contains(.india))
        #expect(defaults.string(forKey: AppMode.defaultsKey) == "india")   // not forgotten

        router.reset()   // another ledger
        #expect(router.mode == .india)
        router.indiaLoaded([.overview, .kite, .coin])
        #expect(router.mode == .india)

        router.switchMode(.wealth)
        router.reset()
        #expect(router.mode == .wealth && router.modes == [.spending, .wealth])
        #expect(TabRouter(defaults: defaults).mode == .wealth)
    }

    @Test("choosing Spending after a fallback is remembered")
    func chooseAfterFallback() {
        let router = TabRouter()
        router.switchMode(.india)
        router.indiaLoaded([])
        #expect(router.mode == .spending)
        router.switchMode(.spending)
        router.reset()
        #expect(router.mode == .spending)
    }
}

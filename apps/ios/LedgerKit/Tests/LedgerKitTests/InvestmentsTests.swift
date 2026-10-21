import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }

@Suite("Investments: the wire")
struct InvestmentsDecodingTests {
    static func valuation() throws -> HoldingsValuation {
        try LedgerJSON.decode(HoldingsValuation.self, from: try fixture("holdings_valuation"))
    }

    @Test("holdings_valuation: totals, every price (keys in either spelling) and each holding, exactly")
    func valuation() throws {
        let v = try Self.valuation()
        #expect(v.valueAed == dec("656286.21") && v.costAed == dec("524000.00") && v.gainAed == dec("93249.96"))
        #expect(v.gainPct == dec("17.80") && v.change24hAed == dec("-1463.63"))
        #expect(v.complete && !v.costsComplete && v.staleCount == 0 && v.holdingsCount == 4)
        #expect(Set(v.prices.keys) == Set(MetalQuote.allCases))
        #expect(v.prices[.gold24k]?.aedPerGram == dec("496.000000") && v.prices[.gold24k]?.change24hPct == dec("-0.13"))
        #expect(v.prices[.gold18k]?.change24hPct == nil)
        let bar = try #require(v.holdings.first { $0.name == "Ten tola bar" })
        #expect(bar.metal == .gold && bar.karat == 24 && bar.fineness == 9950 && bar.grams == dec("116.640"))
        #expect(bar.form == .bar && bar.imagePath == "gold-bar.jpg" && bar.acquiredOn == day("2026-03-15"))
        let bangles = try #require(v.holdings.first { $0.name == "Bangles" })
        #expect(bangles.costAed == nil && bangles.gainAed == nil && bangles.form == .jewellery && bangles.notes == "Wedding set")
        let silver = try #require(v.holdings.first { $0.metal == .silver })
        #expect(silver.purity == dec("0.999") && silver.karat == nil && silver.imagePath == "silver-bar.jpg")
    }

    @Test("a prices key matches with or without underscores; unknown keys are dropped")
    func quoteKeys() {
        #expect(MetalQuote(wireKey: "gold_24k") == .gold24k && MetalQuote(wireKey: "gold24k") == .gold24k)
        #expect(MetalQuote(wireKey: "silverRetail") == .silverRetail && MetalQuote(wireKey: "platinum") == nil)
    }

    @Test("the series: value and cost per day, a price per day")
    func series() throws {
        let value = try LedgerJSON.decode([HoldingValuePoint].self, from: try fixture("holdings_value_series"))
        #expect(value.count == 5 && value.last?.valueAed == dec("656286.21") && value.last?.costAed == dec("524000.00"))
        let price = try LedgerJSON.decode([MetalPricePoint].self, from: try fixture("metal_price_series"))
        #expect(price.count == 4 && price.last?.date == day("2026-10-21") && price.last?.aedPerGram != nil)
        let gaps = [MetalPricePoint(date: day("2026-10-01"), aedPerGram: nil),
                    MetalPricePoint(date: day("2026-10-03"), aedPerGram: 7), MetalPricePoint(date: day("2026-10-02"), aedPerGram: 6)]
        #expect(InvestmentsChart.known(gaps).map(\.date) == [day("2026-10-02"), day("2026-10-03")])
        #expect(InvestmentsChart.axisLabel(7.955) == "7.96" && InvestmentsChart.axisLabel(496) == "496")
        #expect(InvestmentsChart.axisLabel(650_000) == "650k")
    }

    @Test("net worth adds the holdings; an older server's answer reads as none")
    func netWorth() throws {
        let worth = try LedgerJSON.decode(NetWorth.self, from: try fixture("net_worth_holdings"))
        #expect(worth.holdingsAed == dec("656286.21") && worth.holdingsCount == 4 && worth.holdingsComplete)
        #expect(worth.showsHoldings && worth.holdingsAdditionText == "+AED 656,286.21")
        let old = try LedgerJSON.decode(NetWorth.self, from: try fixture("net_worth"))
        #expect(old.holdingsAed == 0 && !old.showsHoldings)
        let points = try LedgerJSON.decode([NetWorthPoint].self, from: try fixture("net_worth_series"))
        #expect(points.allSatisfy { $0.holdingsAed == 0 })
    }

    @Test("net worth's words: stale or missing prices are a caveat; a whole figure names the holdings")
    func netWorthWords() {
        let whole = NetWorth(cashAed: 10, holdingsAed: 5, holdingsCount: 1, owedAed: 2, netAed: 13)
        #expect(whole.completenessText == "Every bank account, card and holding is counted." && whole.caveats.isEmpty)
        let stale = NetWorth(cashAed: 10, holdingsAed: 5, holdingsComplete: false, holdingsCount: 1, owedAed: 2,
                             netAed: 13, complete: false)
        #expect(stale.caveats == ["Some investment prices or values are missing or out of date, so investments may be off."])
        #expect(NetWorth(cashAed: 1, owedAed: 0, netAed: 1).completenessText == "Every bank account and card is counted.")
    }
}

@Suite("Investments: the holding form")
struct HoldingDraftTests {
    let today = day("2026-10-21")

    func draft(_ weight: String, _ unit: WeightUnit = .grams) -> HoldingDraft {
        var d = HoldingDraft(today: today)
        d.name = "Bar"
        d.weight = weight
        d.unit = unit
        return d
    }

    @Test("weights convert exactly to grams with three places: g, kg and tola (11.6638 g)")
    func units() {
        #expect(draft("10", .tola).gramsText == "116.638")
        #expect(draft("3", .tola).gramsText == "34.991")
        #expect(draft("0.5", .tola).gramsText == "5.832")   // 5.8319, half up
        #expect(draft("1", .kilograms).gramsText == "1000.000")
        #expect(draft("1,000.5").gramsText == "1000.500")
        #expect(draft("10", .tola).gramsPreview == "= 116.638 g" && draft("10").gramsPreview == nil)
        #expect(draft("5O").grams == nil && draft("-1").grams == nil && draft("0").grams == nil)
    }

    @Test("validation: name, weight, cost, date and notes, each in words")
    func validation() {
        var d = draft("10", .tola)
        #expect(d.validate(today: today) == nil)
        d.name = "  "
        #expect(d.validate(today: today) == "Give the holding a name, e.g. Ten tola bar.")
        d = draft("abc")
        #expect(d.validate(today: today)?.hasPrefix("Enter the weight") == true)
        #expect(draft("0.0004").validate(today: today) == "The weight is under 0.001 g.")
        for bad in ["-5", "12.345", "1e3", "12a"] {
            d = draft("10")
            d.cost = bad
            #expect(d.validate(today: today) == "Enter what you paid in AED, e.g. 52000, or leave it empty.")
        }
        d = draft("10")
        d.cost = "52,000.50"
        #expect(d.validate(today: today) == nil && d.submission(today: today)?.costAed == "52000.50")
        d.hasAcquiredOn = true
        d.acquiredOn = day("2026-10-22")
        #expect(d.validate(today: today) == "The date bought can't be in the future.")
        d.acquiredOn = today
        d.notes = String(repeating: "x", count: 501)
        #expect(d.validate(today: today) == "Keep the notes to 500 characters.")
        #expect(draft("x").submission(today: today) == nil)
    }

    @Test("what is sent: 24K carries fineness, other karats none, silver its purity; form defaults by metal and karat")
    func submission() throws {
        var gold = draft("10", .tola)
        gold.fineness = .f9950
        gold.cost = ""
        let g = try #require(gold.submission(today: today))
        #expect(g.metal == .gold && g.karat == 24 && g.fineness == 9950 && g.purity == nil && g.grams == "116.638")
        #expect(g.form == .bar && g.costAed == nil && g.acquiredOn == nil && g.notes == nil && g.holdingCode == nil)

        gold.karat = .k22
        let k22 = try #require(gold.submission(today: today))
        #expect(k22.karat == 22 && k22.fineness == nil && k22.form == .jewellery && !gold.asksFineness)
        gold.form = .coin
        #expect(gold.submission(today: today)?.form == .coin)

        var silver = draft("8", .kilograms)
        silver.metal = .silver
        silver.purity = .sterling
        let s = try #require(silver.submission(today: today))
        #expect(s.karat == nil && s.fineness == nil && s.purity == "0.925" && s.form == .bar && s.grams == "8000.000")
    }

    @Test("forms: jewellery is gold only; a jewellery pick falls back to a bar for silver")
    func forms() {
        #expect(HoldingForm.choices(for: .gold) == [.bar, .coin, .jewellery])
        #expect(HoldingForm.choices(for: .silver) == [.bar, .coin])
        #expect(HoldingForm.defaultForm(metal: .gold, karat: 24) == .bar)
        #expect(HoldingForm.defaultForm(metal: .gold, karat: 18) == .jewellery)
        #expect(HoldingForm.defaultForm(metal: .silver, karat: nil) == .bar)
        var d = draft("10")
        d.form = .jewellery
        d.metal = .silver
        #expect(d.form == .bar && d.formChoices == [.bar, .coin] && d.validate(today: today) == nil)
        d.metal = .gold
        #expect(d.form == .jewellery)
        #expect(HoldingForm.coin.imagePath(metal: .silver) == "silver-coin.jpg")
        #expect(HoldingForm.jewellery.imageLabel(metal: .gold) == "Gold jewellery")
    }

    @Test("editing starts from the server's holding, in grams")
    func edit() throws {
        let v = try InvestmentsDecodingTests.valuation()
        let bar = try #require(v.holdings.first { $0.name == "Ten tola bar" })
        let d = HoldingDraft(holding: bar, today: today)
        #expect(d.isEditing && d.title == "Edit holding" && d.saveLabel == "Save")
        #expect(d.weight == "116.64" && d.unit == .grams && d.fineness == .f9950 && d.cost == "52000.00")
        #expect(d.hasAcquiredOn && d.acquiredOn == day("2026-03-15") && d.form == .bar)
        #expect(d.submission(today: today)?.holdingCode == bar.holdingCode)
        let bangles = try #require(v.holdings.first { $0.name == "Bangles" })
        let b = HoldingDraft(holding: bangles, today: today)
        #expect(b.karat == .k22 && b.cost == "" && !b.hasAcquiredOn && b.notes == "Wedding set" && b.form == .jewellery)
    }

    @Test("karat, fineness and purity labels; an unlisted purity is still offered")
    func labels() {
        #expect(GoldFineness.allCases.map(\.label) == ["999.9", "999.5", "999", "995"])
        #expect(GoldKarat.allCases.map(\.label) == ["24K", "22K", "21K", "18K"])
        #expect(SilverPurity.fine.label == "999 fine" && SilverPurity.sterling.millesimal == "925")
        let odd = SilverPurity(dec("0.9999"))
        #expect(odd.label == "999.9" && SilverPurity.choices(including: odd).last == odd)
        #expect(SilverPurity.choices(including: SilverPurity(dec("0.9990"))) == SilverPurity.standard)
    }

    @Test("the server's refusals in words")
    func messages() {
        #expect(HoldingDraft.message(for: LedgerAPIError.server(status: nil, code: "42501", message: "x"))
                == HoldingDraft.ownerOnlyMessage)
        #expect(HoldingDraft.message(for: LedgerAPIError.server(status: nil, code: "22023", message: "grams must be above 0"))
                == "Check the holding: grams must be above 0.")
        #expect(HoldingDraft.message(for: LedgerAPIError.server(status: nil, code: "P0002", message: "holding not found"))
                .contains("isn't in the ledger"))
    }
}

@Suite("Investments: words and photos")
struct InvestmentsPresentationTests {
    @Test("weights, signed amounts and percents")
    func words() {
        #expect(HoldingsText.weight(dec("1000.000")) == "1,000 g" && HoldingsText.weight(dec("116.638")) == "116.638 g")
        #expect(HoldingsText.weight(dec("85.000")) == "85 g")
        #expect(HoldingsText.signedAed(dec("76000")) == "+AED 76,000.00" && HoldingsText.signedAed(dec("-640")) == "−AED 640.00")
        #expect(HoldingsText.signedAed(0) == "AED 0.00")
        #expect(HoldingsText.signedPercent(dec("17.8")) == "+17.80%" && HoldingsText.signedPercent(dec("-0.13")) == "−0.13%")
        #expect(HoldingsText.tone(dec("-1")) == .danger && HoldingsText.tone(dec("1")) == .positive && HoldingsText.tone(nil) == .neutral)
    }

    @Test("a holding row: detail, value, gain or why not, 24h change")
    func row() throws {
        let v = try InvestmentsDecodingTests.valuation()
        let kilo = try #require(v.holdings.first { $0.name == "1 kg bar" })
        #expect(kilo.detail == "24K · 999.9 · 1,000 g" && kilo.valueText == "AED 496,000.00")
        #expect(kilo.gainText == "+AED 76,000.00 (+18.10%)" && kilo.gainTone == .positive)
        #expect(kilo.changeText == "−AED 640.00 in 24h" && kilo.changeTone == .danger)
        let bangles = try #require(v.holdings.first { $0.name == "Bangles" })
        #expect(bangles.detail == "22K gold · 85 g" && bangles.gainText == nil && bangles.noGainText == "No cost entered")
        let silver = try #require(v.holdings.first { $0.metal == .silver })
        #expect(silver.detail == "Silver 999 · 8,000 g" && silver.imageLabel == "Silver bar")
        let unpriced = Holding(holdingCode: "hld_x", name: "New", metal: .gold, grams: 1, karat: 21, costAed: 100)
        #expect(unpriced.valueText == "No price yet" && unpriced.noGainText == "No price yet")
        #expect(unpriced.form == .jewellery && unpriced.imagePath == "gold-jewellery.jpg")
    }

    @Test("a stale price says how old it is")
    func stale() {
        let now = Date(timeIntervalSince1970: 1_792_540_800)   // 2026-10-21 04:00 Dubai
        let asOf = now.addingTimeInterval(-5 * 86_400)
        let h = Holding(holdingCode: "hld_s", name: "Old", metal: .silver, grams: 10, purity: 1, priceAsOf: asOf,
                        priceIsStale: true)
        #expect(h.staleText(now: now) == "Price as of 5 days ago: it hasn't updated for over 3 days.")
        let fresh = Holding(holdingCode: "hld_f", name: "New", metal: .silver, grams: 10, purity: 1, priceAsOf: now)
        #expect(fresh.staleText(now: now) == nil)
    }

    @Test("totals: gain, change, the retail strip in order and what the figures leave out")
    func totals() throws {
        let v = try InvestmentsDecodingTests.valuation()
        #expect(v.heroAmount == "656,286" && v.gainText == "+AED 93,249.96 (+17.80%)" && v.changeText == "−AED 1,463.63")
        #expect(v.retailPrices.map(\.quote) == MetalQuote.retail)
        #expect(v.prices[.gold24k]?.changeText == "−0.13%" && v.prices[.gold24k]?.priceText == "AED 496.00")
        #expect(v.caveats == ["1 holding has no cost, so the gain leaves it out. Add what you paid to count it."])
        let rough = HoldingsValuation(valueAed: 10, complete: false, costsComplete: true, staleCount: 2, holdings: [
            Holding(holdingCode: "a", name: "A", metal: .gold, grams: 1, karat: 24, costAed: 1),
            Holding(holdingCode: "b", name: "B", metal: .gold, grams: 1, karat: 24, costAed: 1, valueAed: 10),
        ])
        #expect(rough.caveats == ["1 holding has no price or value yet, so the total leaves it out.",
                                  "2 holdings are valued at out-of-date prices or values."])
        #expect(HoldingsValuation(valueAed: 0).pricesNote().hasPrefix("No gold or silver prices yet"))
        #expect(HoldingsValuation.emptyMessage(canEdit: false).contains("Owners can add"))
    }

    @Test("photos come from the public bucket, as bank logos do; a path with a slash is refused")
    func photos() throws {
        let base = try #require(URL(string: "http://127.0.0.1:54321"))
        #expect(HoldingImage.url(imagePath: "gold-bar.jpg", supabaseURL: base)?.absoluteString
                == "http://127.0.0.1:54321/storage/v1/object/public/investment-images/gold-bar.jpg")
        #expect(HoldingImage.url(imagePath: "../bank-logos/FAB.png", supabaseURL: base) == nil)
        #expect(HoldingImage.url(imagePath: "gold-bar.jpg", supabaseURL: nil) == nil)
        #expect(BankDirectory.logoURL(supabaseURL: base, logoPath: "FAB.png")?.absoluteString
                == "http://127.0.0.1:54321/storage/v1/object/public/bank-logos/FAB.png")
        var d = HoldingDraft()
        d.metal = .silver
        d.form = .coin
        #expect(d.imageURL(supabaseURL: base)?.lastPathComponent == "silver-coin.jpg")
    }
}

@Suite("Investments: the screen model")
@MainActor
struct InvestmentsModelTests {
    static func api() throws -> StubAPI {
        let api = StubAPI()
        api.valuationFixture = try InvestmentsDecodingTests.valuation()
        api.valueSeriesFixture = try LedgerJSON.decode([HoldingValuePoint].self, from: try fixture("holdings_value_series"))
        api.priceSeriesFixture = try LedgerJSON.decode([MetalPricePoint].self, from: try fixture("metal_price_series"))
        return api
    }

    func model(_ api: StubAPI) -> InvestmentsModel { InvestmentsModel(api: api, today: { day("2026-10-21") }) }

    @Test("loads the valuation and 90 days of value; a price chart loads its quote once")
    func load() async throws {
        let api = try Self.api()
        let m = model(api)
        await m.load(profileCode: "prf_a")
        let content = try #require(m.state.value)
        #expect(content.valuation.holdingsCount == 4 && content.series.count == 5 && content.seriesError == nil)
        #expect(api.valueSeriesRanges.last?.from == day("2026-07-24") && api.valueSeriesRanges.last?.to == day("2026-10-21"))
        #expect(m.selectedPrices == nil && api.calls("metalPriceSeries") == 0)
        await m.selectChart(.silver)
        #expect(api.priceSeriesCalls.last?.quote == .silverRetail && m.selectedPrices?.value?.count == 4)
        await m.selectChart(.value)
        await m.selectChart(.silver)
        #expect(api.calls("metalPriceSeries") == 1)
        await m.selectChart(.gold24k)
        #expect(api.priceSeriesCalls.last?.quote == .gold24k)
    }

    @Test("the series failing keeps the holdings; the valuation failing fails the screen")
    func failures() async throws {
        let api = try Self.api()
        api.valueSeriesError = .network("-1009")
        let m = model(api)
        await m.load(profileCode: "prf_a")
        #expect(m.state.value?.series.isEmpty == true && m.state.value?.seriesError != nil)
        api.valuationFixture = nil
        let failing = model(api)
        await failing.load(profileCode: "prf_a")
        #expect(failing.state.value == nil && failing.state.errorMessage != nil)
    }

    @Test("save: owners only, validated before the call; success reloads and tells Overview")
    func save() async throws {
        let api = try Self.api()
        let m = model(api)
        var told: [String] = []
        m.onChange = { told.append($0) }
        await m.load(profileCode: "prf_a")
        var d = m.newDraft()
        d.name = "Ten tola bar"
        d.weight = "10"
        d.unit = .tola
        d.fineness = .f9950
        #expect(await m.save(d, profileCode: "prf_a", canEdit: false) == HoldingDraft.ownerOnlyMessage)
        var bad = d
        bad.weight = ""
        #expect(await m.save(bad, profileCode: "prf_a", canEdit: true)?.hasPrefix("Enter the weight") == true)
        #expect(api.savedHoldings.isEmpty)
        #expect(await m.save(d, profileCode: "prf_a", canEdit: true) == nil)
        #expect(api.savedHoldings.last?.grams == "116.638" && api.savedHoldings.last?.fineness == 9950)
        #expect(m.notice?.text == "Ten tola bar added." && told == ["prf_a"] && api.calls("holdingsValuation") == 2)

        api.holdingWriteError = .server(status: nil, code: "22023", message: "form must be bar, coin or (gold only) jewellery")
        #expect(await m.save(d, profileCode: "prf_a", canEdit: true)?.hasPrefix("Check the holding: form must be") == true)
    }

    @Test("close: owners only; the server's refusal in words")
    func close() async throws {
        let api = try Self.api()
        let m = model(api)
        await m.load(profileCode: "prf_a")
        let holding = try #require(m.state.value?.valuation.holdings.first)
        #expect(await m.close(holding, profileCode: "prf_a", canEdit: false) == HoldingDraft.ownerOnlyMessage)
        #expect(await m.close(holding, profileCode: "prf_a", canEdit: true) == nil)
        #expect(api.closedHoldings == [holding.holdingCode] && m.notice?.text == "1 kg bar closed.")
        #expect(InvestmentsModel.closeTitle(holding) == "Close 1 kg bar?")
        api.holdingWriteError = .server(status: nil, code: "P0002", message: "holding not found")
        #expect(await m.close(holding, profileCode: "prf_a", canEdit: true)?.contains("isn't in the ledger") == true)
    }

    @Test("Wealth's Overview carries the investments, and goes on without them")
    func overview() async throws {
        let api = try WealthScreensTests.api()
        api.valuationFixture = try InvestmentsDecodingTests.valuation()
        let overview = WealthOverviewModel(api: api, today: { day("2026-10-20") })
        await overview.load(profileCode: "prf_a")
        #expect(overview.state.value?.investments?.holdingsCount == 4)
        api.valuationFixture = nil
        await overview.load(profileCode: "prf_a")
        #expect(overview.state.value != nil && overview.state.value?.investments == nil)
    }
}

import Foundation

/// Words and signs for the Investments screen. Every figure is the server's; these only format.
public enum HoldingsText {
    /// `"1,000 g"`, `"116.638 g"`, `"85 g"`: up to three decimals, trailing zeros dropped.
    public static func weight(_ grams: Decimal) -> String {
        var s = MoneyFormat.grouped(grams, fractionDigits: 3)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + " g"
    }

    /// `"+AED 76,000.00"`, `"−AED 640.00"` (a true minus sign), `"AED 0.00"`.
    public static func signedAed(_ value: Decimal) -> String {
        let text = MoneyFormat.aed(value < 0 ? -value : value)
        if MoneyFormat.rounded(value, scale: 2) == 0 { return text }
        return (value < 0 ? "−" : "+") + text
    }

    /// A server percent (`"17.80"`, already ×100) as `"+17.80%"`, `"−0.13%"`, `"0.00%"`.
    public static func signedPercent(_ pct: Decimal) -> String {
        let text = MoneyFormat.grouped(pct < 0 ? -pct : pct, fractionDigits: 2) + "%"
        if MoneyFormat.rounded(pct, scale: 2) == 0 { return text }
        return (pct < 0 ? "−" : "+") + text
    }

    /// Up is positive, down is danger, flat (or unknown) is neutral.
    public static func tone(_ value: Decimal?) -> Tone {
        guard let value, MoneyFormat.rounded(value, scale: 2) != 0 else { return .neutral }
        return value > 0 ? .positive : .danger
    }

    /// `"AED 496.00/g"`.
    public static func perGram(_ aed: Decimal) -> String { MoneyFormat.aed(aed) + "/g" }

    /// `"1 holding"`, `"3 holdings"`.
    static func holdings(_ n: Int) -> String { n == 1 ? "1 holding" : "\(n) holdings" }

    /// `"2,000 units"`, `"12.5 units"`, `"1 unit"`: up to six decimals, trailing zeros dropped.
    public static func units(_ units: Decimal) -> String {
        let text = HoldingDraft.trimmed(units, places: 6)
        let grouped = MoneyFormat.grouped(LedgerDecimal.parse(text) ?? units,
                                          fractionDigits: text.split(separator: ".").dropFirst().first?.count ?? 0)
        return grouped + (units == 1 ? " unit" : " units")
    }
}

extension Holding {
    /// The row's second line, by kind: `"24K · 999.9 · 1,000 g"`, `"22K gold · 85 g"`,
    /// `"Silver 999 · 8,000 g"`, `"RL360 · USD"`, `"TALABAT · 2,000 units"`,
    /// `"Wio · 4.25% · matures 23 Jun 2027"`.
    public func detail(today: CalendarDay = LedgerDates.today()) -> String {
        switch kind {
        case .metal:
            let weight = grams.map(HoldingsText.weight) ?? ""
            switch metal {
            case .gold?:
                let k = karat.map { "\($0)K" } ?? "Gold"
                if let f = fineness.flatMap(GoldFineness.init(rawValue:)) { return "\(k) · \(f.label) · \(weight)" }
                return "\(k) gold · \(weight)"
            case .silver?:
                return (purity.map { "Silver \(SilverPurity($0).millesimal)" } ?? "Silver") + " · \(weight)"
            case nil:
                return weight
            }
        case .plan, .broker, .structuredNote:
            return [institution ?? kind.label, currency == "AED" ? nil : currency].compactMap { $0 }.joined(separator: " · ")
        case .security:
            let u = units.map { HoldingsText.units($0) }
            return [symbol ?? institution, u, currency == "AED" ? nil : currency].compactMap { $0 }.joined(separator: " · ")
        case .deposit:
            let rate = ratePct.map { MoneyFormat.grouped($0, fractionDigits: 2) + "%" }
            let matures = maturityOn.map { day in
                (day <= today ? "matured " : "matures ") + LedgerDates.dayLabel(day, today: today)
            }
            return [institution, rate, matures].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// `"24K · 999.9 · 1,000 g"`: the detail as of today.
    public var detail: String { detail() }

    /// The row's photo (metals only); nil without the project URL.
    public func imageURL(supabaseURL: URL?) -> URL? { HoldingImage.url(imagePath: imagePath, supabaseURL: supabaseURL) }
    /// VoiceOver for the photo: `"Gold bar"`; the kind for the others.
    public var imageLabel: String {
        if let metal, let form { return form.imageLabel(metal: metal) }
        return kind.label
    }
    /// Metals show their photo; the other kinds the kind's symbol.
    public var hasPhoto: Bool { kind == .metal && imagePath != nil }

    /// `"AED 496,000.00"`, or `"No price yet"` (a metal) / `"No value yet"`.
    public var valueText: String {
        if let valueAed { return MoneyFormat.aed(valueAed) }
        return kind == .metal ? "No price yet" : "No value yet"
    }
    public var hasValue: Bool { valueAed != nil }

    /// The value in the holding's own currency beside the AED: `"USD 53,800.00"`; nil for AED.
    public var ownValueText: String? {
        guard currency != "AED", let value else { return nil }
        return MoneyFormat.amount(value, currency: currency)
    }

    /// `"+AED 76,000.00 (+18.10%)"`; nil without a cost (or a value).
    public var gainText: String? {
        guard let gainAed else { return nil }
        return HoldingsText.signedAed(gainAed) + (gainPct.map { " (\(HoldingsText.signedPercent($0)))" } ?? "")
    }

    public var gainTone: Tone { HoldingsText.tone(gainAed) }

    /// What the row says instead of a gain.
    public var noGainText: String {
        if valueAed == nil { return kind == .metal ? "No price yet" : "No value yet" }
        if costAed == nil { return kind == .metal ? "No cost entered" : "No money in recorded" }
        return "No gain yet"
    }

    /// `"−AED 640.00 in 24h"`; nil without yesterday's figure, and when nothing moved (a plan's
    /// value changes only when one is recorded; prices may not have updated).
    public var changeText: String? {
        guard let change24hAed, MoneyFormat.rounded(change24hAed, scale: 2) != 0 else { return nil }
        return HoldingsText.signedAed(change24hAed) + " in 24h"
    }
    public var changeTone: Tone { HoldingsText.tone(change24hAed) }

    /// `"Income AED 440.70"`; nil without any.
    public var incomeText: String? {
        guard let incomeAed, incomeAed != 0 else { return nil }
        return "Income " + MoneyFormat.aed(incomeAed)
    }

    /// When the value is from, for kinds you value yourself: `"Value as of 1 Oct"`, a deposit's
    /// `"Profit accrued to 21 Oct"`; nil for metals (their price says) and before any value.
    public func asOfText(today: CalendarDay = LedgerDates.today()) -> String? {
        guard kind != .metal, let valueAsOf else { return nil }
        if isEstimate { return "Profit accrued to " + LedgerDates.dayLabel(valueAsOf, today: today) }
        let what = kind == .security ? "Price" : "Value"
        return "\(what) as of " + LedgerDates.dayLabel(valueAsOf, today: today)
    }

    /// `"Estimated"`: a deposit's accrued value; nil otherwise.
    public var estimateLabel: String? { isEstimate ? "Estimated" : nil }

    /// A stale figure in words: a metal price over 3 days old, or a value over 45 days old. Nil while fresh.
    public func staleText(now: Date = .now) -> String? {
        guard priceIsStale else { return nil }
        if kind == .metal {
            guard let priceAsOf else { return nil }
            return "Price " + CashText.asOf(priceAsOf, now: now).lowercasedFirst + ": it hasn't updated for over 3 days."
        }
        let what = kind == .security ? "price" : "value"
        guard let valueAsOf else { return "No recent \(what): record one." }
        return "The \(what) is from " + LedgerDates.dayLabel(valueAsOf, today: LedgerDates.today(now: now))
            + ", over 45 days ago. Record a newer one."
    }

    /// How the payment rule matches: `"containing “RL360”"`, `"described exactly “RI”"`; nil without one.
    public var linkRuleMatch: String? {
        linkPattern.map { linkExact ? "described exactly “\($0)”" : "containing “\($0)”" }
    }

    /// The holding screen's rule line: `"Links payments containing “RL360”"`.
    public var linkRuleText: String? { linkRuleMatch.map { "Links payments " + $0 } }

    /// Whether the owner's Update value applies (plans, broker accounts, shares and funds).
    public var canRecordValue: Bool { kind.recordsValue }

    /// VoiceOver: `"1 kg bar, 24K · 999.9 · 1,000 g, AED 496,000.00, gain +AED 76,000.00 (+18.10%)"`.
    public var accessibilityLabel: String {
        "\(name), \(detail), \(valueText)" + (ownValueText.map { ", \($0)" } ?? "") + ", "
            + (gainText.map { "gain \($0)" } ?? noGainText)
            + (changeText.map { ", \($0)" } ?? "") + (estimateLabel.map { ", \($0.lowercased())" } ?? "")
    }
}

/// The holdings of one kind, in the server's order (most valuable first). A group carries no
/// subtotal: totals are the server's (CLAUDE.md §2.2).
public struct HoldingGroup: Sendable, Hashable, Identifiable {
    public var id: HoldingKind { kind }
    public let kind: HoldingKind
    public let holdings: [Holding]

    public var title: String { kind.groupTitle }
    /// `"2 holdings"`.
    public var countText: String { HoldingsText.holdings(holdings.count) }

    /// `holdings` by kind in `HoldingKind` order, each kind keeping their order; empty kinds left out.
    public static func groups(_ holdings: [Holding]) -> [HoldingGroup] {
        HoldingKind.allCases.compactMap { kind in
            let inKind = holdings.filter { $0.kind == kind }
            return inKind.isEmpty ? nil : HoldingGroup(kind: kind, holdings: inKind)
        }
    }
}

extension MetalPrice {
    /// `"AED 496.00"`.
    public var priceText: String { MoneyFormat.aed(aedPerGram) }
    /// `"−0.13%"`; nil without a price 24 hours earlier.
    public var changeText: String? { change24hPct.map(HoldingsText.signedPercent) }
    public var changeTone: Tone { HoldingsText.tone(change24hPct) }
    /// `"As of today, 11:23"`.
    public func asOfText(now: Date = .now) -> String { CashText.asOf(asOf, now: now) }
}

extension HoldingsValuation {
    /// The hero number without its unit: `"656,286"`.
    public var heroAmount: String { MoneyFormat.hero(valueAed) }
    public var valueText: String { MoneyFormat.aed(valueAed) }
    public var heroAccessibilityLabel: String { "Investments, \(MoneyFormat.spokenDirhams(valueAed))" }
    public var isEmpty: Bool { holdingsCount == 0 }

    /// `"+AED 93,249.96 (+17.80%)"`; nil when no holding has a cost.
    public var gainText: String? {
        guard let gainAed else { return nil }
        return HoldingsText.signedAed(gainAed) + (gainPct.map { " (\(HoldingsText.signedPercent($0)))" } ?? "")
    }

    public var gainTone: Tone { HoldingsText.tone(gainAed) }

    /// `"−AED 1,463.63"`; nil without prices 24 hours earlier.
    public var changeText: String? { change24hAed.map(HoldingsText.signedAed) }
    public var changeTone: Tone { HoldingsText.tone(change24hAed) }

    /// The holdings with no cost: the gain leaves them out.
    public var withoutCostCount: Int { holdings.filter { $0.costAed == nil }.count }
    /// The holdings with no price: the value leaves them out.
    public var withoutPriceCount: Int { holdings.filter { $0.valueAed == nil }.count }

    /// What the figures can't vouch for, in plain words; empty when whole and fresh.
    public var caveats: [String] {
        var out: [String] = []
        if !complete, withoutPriceCount > 0 {
            out.append(withoutPriceCount == 1
                ? "1 holding has no price or value yet, so the total leaves it out."
                : "\(withoutPriceCount) holdings have no price or value yet, so the total leaves them out.")
        }
        if staleCount > 0 {
            out.append(staleCount == 1
                ? "1 holding is valued at an out-of-date price or value."
                : "\(staleCount) holdings are valued at out-of-date prices or values.")
        }
        if !costsComplete, withoutCostCount > 0 {
            out.append(withoutCostCount == 1
                ? "1 holding has no cost, so the gain leaves it out. Add what you paid to count it."
                : "\(withoutCostCount) holdings have no cost, so the gain leaves them out. Add what you paid to count them.")
        }
        if holdings.contains(where: \.isEstimate) {
            out.append("Fixed deposits are estimated: profit accrues each day to maturity.")
        }
        return out
    }

    /// The Dubai retail prices the holdings are valued at, in the strip's order (those known).
    public var retailPrices: [(quote: MetalQuote, price: MetalPrice)] {
        MetalQuote.retail.compactMap { q in prices[q].map { (q, $0) } }
    }

    /// `"Dubai retail prices, as of today, 11:23. They refresh every 6 hours."`
    public func pricesNote(now: Date = .now) -> String {
        guard let latest = retailPrices.map(\.price.asOf).max() else {
            return "No gold or silver prices yet. They refresh every 6 hours."
        }
        return "Dubai retail prices per gram, " + CashText.asOf(latest, now: now).lowercasedFirst
            + ". They refresh every 6 hours."
    }

    /// `"4 holdings"`.
    public var countText: String { HoldingsText.holdings(holdingsCount) }

    /// The holdings by kind (gold and silver, plans, broker accounts, shares and funds, deposits),
    /// each in the server's order; a kind with none is left out.
    public var groups: [HoldingGroup] { HoldingGroup.groups(holdings) }

    /// The price strip shows while there is gold or silver to price (or before any holding).
    public var showsMetalPrices: Bool { isEmpty || holdings.contains { $0.kind == .metal } }

    /// The holding with this code, if still active.
    public func holding(_ code: String) -> Holding? { holdings.first { $0.holdingCode == code } }

    /// No holdings yet, in words for who is reading.
    public static func emptyMessage(canEdit: Bool) -> String {
        canEdit
            ? "No investments yet. Add gold or silver, a plan, a broker account, shares or a fixed deposit."
            : "No investments in this ledger yet. Owners can add holdings."
    }
}

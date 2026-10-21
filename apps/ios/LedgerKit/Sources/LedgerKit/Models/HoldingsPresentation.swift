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
}

extension Holding {
    /// `"24K · 999.9 · 1,000 g"`, `"22K gold · 85 g"`, `"Silver 999 · 8,000 g"`.
    public var detail: String {
        let weight = HoldingsText.weight(grams)
        switch metal {
        case .gold:
            let k = karat.map { "\($0)K" } ?? "Gold"
            if let f = fineness.flatMap(GoldFineness.init(rawValue:)) { return "\(k) · \(f.label) · \(weight)" }
            return "\(k) gold · \(weight)"
        case .silver:
            return (purity.map { "Silver \(SilverPurity($0).millesimal)" } ?? "Silver") + " · \(weight)"
        }
    }

    /// The row's photo; nil without the project URL.
    public func imageURL(supabaseURL: URL?) -> URL? { HoldingImage.url(imagePath: imagePath, supabaseURL: supabaseURL) }
    /// VoiceOver for the photo: `"Gold bar"`.
    public var imageLabel: String { form.imageLabel(metal: metal) }

    /// `"AED 496,000.00"`, or `"No price yet"`.
    public var valueText: String { valueAed.map { MoneyFormat.aed($0) } ?? "No price yet" }
    public var hasValue: Bool { valueAed != nil }

    /// `"+AED 76,000.00 (+18.10%)"`; nil without a cost (or a price).
    public var gainText: String? {
        guard let gainAed else { return nil }
        return HoldingsText.signedAed(gainAed) + (gainPct.map { " (\(HoldingsText.signedPercent($0)))" } ?? "")
    }

    public var gainTone: Tone { HoldingsText.tone(gainAed) }

    /// What the row says instead of a gain.
    public var noGainText: String { costAed == nil ? "No cost entered" : "No price yet" }

    /// `"−AED 640.00 in 24h"`; nil without yesterday's price.
    public var changeText: String? { change24hAed.map { HoldingsText.signedAed($0) + " in 24h" } }
    public var changeTone: Tone { HoldingsText.tone(change24hAed) }

    /// `"Price AED 496.00/g, 3 days old"` for a stale price; nil while fresh.
    public func staleText(now: Date = .now) -> String? {
        guard priceIsStale, let priceAsOf else { return nil }
        return "Price " + CashText.asOf(priceAsOf, now: now).lowercasedFirst + ": it hasn't updated for over 3 days."
    }

    /// VoiceOver: `"1 kg bar, 24K · 999.9 · 1,000 g, AED 496,000.00, gain +AED 76,000.00 (+18.10%)"`.
    public var accessibilityLabel: String {
        "\(name), \(detail), \(valueText), " + (gainText.map { "gain \($0)" } ?? noGainText)
            + (changeText.map { ", \($0)" } ?? "")
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
                ? "1 holding has no price yet, so the value leaves it out."
                : "\(withoutPriceCount) holdings have no price yet, so the value leaves them out.")
        }
        if staleCount > 0 {
            out.append(staleCount == 1
                ? "1 holding is valued at a price over 3 days old."
                : "\(staleCount) holdings are valued at prices over 3 days old.")
        }
        if !costsComplete, withoutCostCount > 0 {
            out.append(withoutCostCount == 1
                ? "1 holding has no cost, so the gain leaves it out. Add what you paid to count it."
                : "\(withoutCostCount) holdings have no cost, so the gain leaves them out. Add what you paid to count them.")
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

    /// No holdings yet, in words for who is reading.
    public static func emptyMessage(canEdit: Bool) -> String {
        canEdit
            ? "No gold or silver yet. Add a holding with its weight, and what you paid to see the gain."
            : "No gold or silver in this ledger yet. Owners can add holdings."
    }
}

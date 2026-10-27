import Foundation

/// What a holding is (`holdings.kind`): gold or silver priced by the feed, a savings plan, a
/// broker account valued as a whole, shares or a fund (units × a price you enter), or a fixed
/// deposit whose value accrues.
///
/// A structured note comes from the broker sync, which reads its term sheet (`create_structured_note`),
/// never through the holding form: `addable` leaves it out. A kind this build doesn't know decodes as a broker
/// account (valued as a whole) instead of failing the whole response: a new kind on the server
/// once meant every installed build would lose the Investments tab (`HoldingKindDecodingTests`).
public enum HoldingKind: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case metal, plan, broker, security, deposit
    case structuredNote = "structured_note"

    public var id: String { rawValue }

    /// The kinds the holding form adds and edits.
    public static let addable: [HoldingKind] = [.metal, .plan, .broker, .security, .deposit]

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HoldingKind(rawValue: raw) ?? .broker
    }

    /// The kind picker: `"Gold or silver"`, `"Plan"`.
    public var label: String {
        switch self {
        case .metal: "Gold or silver"
        case .plan: "Plan"
        case .broker: "Broker account"
        case .security: "Shares or fund"
        case .deposit: "Fixed deposit"
        case .structuredNote: "Structured note"
        }
    }

    /// The group on Investments: `"Gold and silver"`, `"Plans"`.
    public var groupTitle: String {
        switch self {
        case .metal: "Gold and silver"
        case .plan: "Plans"
        case .broker: "Broker accounts"
        case .security: "Shares and funds"
        case .deposit: "Fixed deposits"
        case .structuredNote: "Structured notes"
        }
    }

    /// The SF Symbol a row shows (metals show their photo instead).
    public var systemImage: String {
        switch self {
        case .metal: "circle.hexagongrid"
        case .plan: "shield.lefthalf.filled"
        case .broker: "chart.line.uptrend.xyaxis"
        case .security: "chart.bar.xaxis"
        case .deposit: "banknote"
        case .structuredNote: "doc.text.magnifyingglass"
        }
    }

    /// Under the kind picker: how the holding is valued.
    public var explanation: String {
        switch self {
        case .metal: "Valued at today's Dubai retail price for its weight and purity."
        case .plan: "A savings or investment plan (RL360 and the like). You record its value from the statement."
        case .broker: "A broker account (IBKR, Swissquote, Sarwa) valued as a whole. You record its value."
        case .security: "Shares or a fund you hold units of. Its value is the units times the price you enter."
        case .deposit: "A fixed deposit. Its value is the principal plus profit accrued to today, an estimate."
        case .structuredNote: "An autocallable or other note, brought in by the broker sync. It counts at what you invested until it ends."
        }
    }

    /// Plans and broker accounts take a value; shares and funds a unit price. Metals are priced by
    /// the feed and deposits accrue, so they take neither.
    public var recordsValue: Bool { self == .plan || self == .broker || self == .security }

    /// Money in and out is recorded for every kind but metals, whose cost is on the holding.
    public var takesFlows: Bool { self != .metal }
}

/// One active holding in `holdings_valuation.holdings`, valued by the server. Metals carry their
/// weight and purity; the other kinds their currency, institution and kind's fields. Every
/// figure is the server's decimal string; nothing is re-derived here.
public struct Holding: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let name: String
    public let kind: HoldingKind
    /// The holding's own currency (`"USD"`); metals are AED.
    public let currency: String
    public let institution: String?
    // Metals
    public let metal: Metal?
    public let grams: Decimal?
    /// 24, 22, 21 or 18 for gold; nil for silver.
    public let karat: Int?
    /// 24K bars, in parts per 10,000 (9999, 9995, 9990, 9950).
    public let fineness: Int?
    /// Silver's fine share (`0.9990`).
    public let purity: Decimal?
    public let form: HoldingForm?
    /// The photo's file in `investment-images` (`"gold-bar.jpg"`); metals only.
    public let imagePath: String?
    public let quote: String?
    public let aedPerGram: Decimal?
    public let priceAsOf: Date?
    // Shares and funds
    public let units: Decimal?
    public let symbol: String?
    // Deposits
    public let principal: Decimal?
    public let ratePct: Decimal?
    public let maturityOn: CalendarDay?
    /// A payment whose description contains this (or, `linkExact`, is exactly this) is linked automatically.
    public let linkPattern: String?
    /// The whole description must equal the rule, case aside (Wio prints RL360 as just "RI").
    public let linkExact: Bool
    /// What it cost: contributions − withdrawals (a metal's cost is its first contribution), AED.
    public let costAed: Decimal?
    /// Income paid out (dividends, coupons), AED.
    public let incomeAed: Decimal?
    /// The purchase date (metals) or start date (a deposit's is required).
    public let acquiredOn: CalendarDay?
    public let notes: String?
    /// In the holding's currency; nil before it has a price or value.
    public let value: Decimal?
    /// The day the value is as of.
    public let valueAsOf: CalendarDay?
    /// A metal's price over 3 days old, or a recorded value over 45 days old.
    public let priceIsStale: Bool
    /// A deposit's accrued value is an estimate.
    public let isEstimate: Bool
    public let flowCount: Int
    /// Nil before the holding has a price or value.
    public let valueAed: Decimal?
    public let gainAed: Decimal?
    public let gainPct: Decimal?
    public let change24hAed: Decimal?

    /// A gold or silver holding (tests and previews).
    public init(holdingCode: String, name: String, metal: Metal, grams: Decimal, karat: Int? = nil,
                fineness: Int? = nil, purity: Decimal? = nil, form: HoldingForm? = nil, imagePath: String? = nil,
                costAed: Decimal? = nil, acquiredOn: CalendarDay? = nil,
                notes: String? = nil, quote: String? = nil, aedPerGram: Decimal? = nil, priceAsOf: Date? = nil,
                priceIsStale: Bool = false, valueAed: Decimal? = nil, gainAed: Decimal? = nil, gainPct: Decimal? = nil,
                change24hAed: Decimal? = nil) {
        let form = form ?? HoldingForm.defaultForm(metal: metal, karat: karat)
        self.init(holdingCode: holdingCode, name: name, kind: .metal, metal: metal, grams: grams, karat: karat,
                  fineness: fineness, purity: purity, form: form, imagePath: imagePath ?? form.imagePath(metal: metal),
                  quote: quote, aedPerGram: aedPerGram, priceAsOf: priceAsOf, costAed: costAed,
                  acquiredOn: acquiredOn, notes: notes, value: valueAed, priceIsStale: priceIsStale,
                  valueAed: valueAed, gainAed: gainAed, gainPct: gainPct, change24hAed: change24hAed)
    }

    /// Any kind, every field named (tests and previews).
    public init(holdingCode: String, name: String, kind: HoldingKind, currency: String = "AED",
                institution: String? = nil, metal: Metal? = nil, grams: Decimal? = nil, karat: Int? = nil,
                fineness: Int? = nil, purity: Decimal? = nil, form: HoldingForm? = nil, imagePath: String? = nil,
                quote: String? = nil, aedPerGram: Decimal? = nil, priceAsOf: Date? = nil, units: Decimal? = nil,
                symbol: String? = nil, principal: Decimal? = nil, ratePct: Decimal? = nil,
                maturityOn: CalendarDay? = nil, linkPattern: String? = nil, linkExact: Bool = false,
                costAed: Decimal? = nil,
                incomeAed: Decimal? = nil, acquiredOn: CalendarDay? = nil, notes: String? = nil,
                value: Decimal? = nil, valueAsOf: CalendarDay? = nil, priceIsStale: Bool = false,
                isEstimate: Bool = false, flowCount: Int = 0, valueAed: Decimal? = nil, gainAed: Decimal? = nil,
                gainPct: Decimal? = nil, change24hAed: Decimal? = nil) {
        self.holdingCode = holdingCode
        self.name = name
        self.kind = kind
        self.currency = currency
        self.institution = institution
        self.metal = metal
        self.grams = grams
        self.karat = karat
        self.fineness = fineness
        self.purity = purity
        self.form = form
        self.imagePath = imagePath
        self.quote = quote
        self.aedPerGram = aedPerGram
        self.priceAsOf = priceAsOf
        self.units = units
        self.symbol = symbol
        self.principal = principal
        self.ratePct = ratePct
        self.maturityOn = maturityOn
        self.linkPattern = linkPattern
        self.linkExact = linkExact
        self.costAed = costAed
        self.incomeAed = incomeAed
        self.acquiredOn = acquiredOn
        self.notes = notes
        self.value = value
        self.valueAsOf = valueAsOf
        self.priceIsStale = priceIsStale
        self.isEstimate = isEstimate
        self.flowCount = flowCount
        self.valueAed = valueAed
        self.gainAed = gainAed
        self.gainPct = gainPct
        self.change24hAed = change24hAed
    }

    enum CodingKeys: String, CodingKey {
        case holdingCode, name, kind, currency, institution, metal, grams, karat, fineness, purity, form, imagePath
        case quote, aedPerGram, priceAsOf, units, symbol, principal, ratePct, maturityOn, linkPattern, linkExact
        case costAed, incomeAed, acquiredOn, notes, value, valueAsOf, priceIsStale, isEstimate, flowCount
        case valueAed, gainAed, gainPct, change24hAed = "change24HAed"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        holdingCode = try c.decode(String.self, forKey: .holdingCode)
        name = try c.decode(String.self, forKey: .name)
        // A server before holding kinds sends none: every holding was gold or silver.
        let kind = try c.decodeIfPresent(HoldingKind.self, forKey: .kind) ?? .metal
        self.kind = kind
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "AED"
        institution = try c.decodeIfPresent(String.self, forKey: .institution)
        let metal = try c.decodeIfPresent(Metal.self, forKey: .metal)
        self.metal = metal
        grams = try c.decodeIfPresent(Decimal.self, forKey: .grams)
        let karat = try c.decodeIfPresent(Int.self, forKey: .karat)
        self.karat = karat
        fineness = try c.decodeIfPresent(Int.self, forKey: .fineness)
        purity = try c.decodeIfPresent(Decimal.self, forKey: .purity)
        // A server before photos sends neither: the metal's default form and that form's photo.
        var decodedForm = try c.decodeIfPresent(HoldingForm.self, forKey: .form)
        if decodedForm == nil, let metal { decodedForm = HoldingForm.defaultForm(metal: metal, karat: karat) }
        form = decodedForm
        var path = try c.decodeIfPresent(String.self, forKey: .imagePath)
        if path == nil, let metal, let decodedForm { path = decodedForm.imagePath(metal: metal) }
        imagePath = path
        quote = try c.decodeIfPresent(String.self, forKey: .quote)
        aedPerGram = try c.decodeIfPresent(Decimal.self, forKey: .aedPerGram)
        priceAsOf = try c.decodeIfPresent(Date.self, forKey: .priceAsOf)
        units = try c.decodeIfPresent(Decimal.self, forKey: .units)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        principal = try c.decodeIfPresent(Decimal.self, forKey: .principal)
        ratePct = try c.decodeIfPresent(Decimal.self, forKey: .ratePct)
        maturityOn = try c.decodeIfPresent(CalendarDay.self, forKey: .maturityOn)
        linkPattern = try c.decodeIfPresent(String.self, forKey: .linkPattern)
        linkExact = try c.decodeIfPresent(Bool.self, forKey: .linkExact) ?? false
        costAed = try c.decodeIfPresent(Decimal.self, forKey: .costAed)
        incomeAed = try c.decodeIfPresent(Decimal.self, forKey: .incomeAed)
        acquiredOn = try c.decodeIfPresent(CalendarDay.self, forKey: .acquiredOn)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        let valueAed = try c.decodeIfPresent(Decimal.self, forKey: .valueAed)
        self.valueAed = valueAed
        // Before kinds, a metal's value was only in AED.
        let own = try c.decodeIfPresent(Decimal.self, forKey: .value)
        value = own ?? (kind == .metal ? valueAed : nil)
        valueAsOf = try c.decodeIfPresent(CalendarDay.self, forKey: .valueAsOf)
        priceIsStale = try c.decodeIfPresent(Bool.self, forKey: .priceIsStale) ?? false
        isEstimate = try c.decodeIfPresent(Bool.self, forKey: .isEstimate) ?? false
        flowCount = try c.decodeIfPresent(Int.self, forKey: .flowCount) ?? 0
        gainAed = try c.decodeIfPresent(Decimal.self, forKey: .gainAed)
        gainPct = try c.decodeIfPresent(Decimal.self, forKey: .gainPct)
        change24hAed = try c.decodeIfPresent(Decimal.self, forKey: .change24hAed)
    }
}

/// One day of `rpc('holdings_value_series')`: the holdings held that day that had a value, at its
/// prices and values, and what they had cost to date. `complete` is false on a day some holding
/// had no value yet (the value leaves it out); `valueAed` is nil when none had one.
public struct HoldingValuePoint: Decodable, Sendable, Hashable, Identifiable {
    public var id: CalendarDay { date }
    public let date: CalendarDay
    public let valueAed: Decimal?
    public let costAed: Decimal?
    public let complete: Bool

    public init(date: CalendarDay, valueAed: Decimal?, costAed: Decimal? = nil, complete: Bool = true) {
        self.date = date
        self.valueAed = valueAed
        self.costAed = costAed
        self.complete = complete
    }

    enum CodingKeys: String, CodingKey { case date, valueAed, costAed, complete }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(CalendarDay.self, forKey: .date)
        let value = try c.decodeIfPresent(Decimal.self, forKey: .valueAed)
        valueAed = value
        costAed = try c.decodeIfPresent(Decimal.self, forKey: .costAed)
        // Before `complete`, a day with a missing value had no value at all.
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? (value != nil)
    }
}

/// One day of `rpc('metal_price_series')`: the quote's last AED/gram price that Dubai day.
public struct MetalPricePoint: Decodable, Sendable, Hashable, Identifiable {
    public var id: CalendarDay { date }
    public let date: CalendarDay
    public let aedPerGram: Decimal?

    public init(date: CalendarDay, aedPerGram: Decimal?) {
        self.date = date
        self.aedPerGram = aedPerGram
    }
}

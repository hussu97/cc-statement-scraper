import Foundation

/// Gold or silver (`holdings.metal`).
public enum Metal: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case gold, silver

    public var id: String { rawValue }
    public var label: String { self == .gold ? "Gold" : "Silver" }
}

/// What a holding is (`holdings.form`): its photo, and jewellery for gold only.
public enum HoldingForm: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case bar, coin, jewellery

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .bar: "Bar"
        case .coin: "Coin"
        case .jewellery: "Jewellery"
        }
    }

    /// Silver is a bar or a coin; gold may also be jewellery.
    public func isAllowed(for metal: Metal) -> Bool { metal == .gold || self != .jewellery }

    /// The form picker's choices.
    public static func choices(for metal: Metal) -> [HoldingForm] { allCases.filter { $0.isAllowed(for: metal) } }

    /// `save_holding`'s default: 24K gold and silver are bars, gold below 24K is jewellery.
    public static func defaultForm(metal: Metal, karat: Int?) -> HoldingForm {
        metal == .gold && (karat ?? 24) != 24 ? .jewellery : .bar
    }

    /// The photo in the `investment-images` bucket: `"gold-bar.jpg"` (the server's `image_path`).
    public func imagePath(metal: Metal) -> String { "\(metal.rawValue)-\(rawValue).jpg" }

    /// VoiceOver for the photo: `"Gold bar"`, `"Silver coin"`, `"Gold jewellery"`.
    public func imageLabel(metal: Metal) -> String { "\(metal.label) \(rawValue)" }
}

/// The holdings' photos, in the public `investment-images` bucket.
public enum HoldingImage {
    public static let bucket = "investment-images"

    /// `{supabaseURL}/storage/v1/object/public/investment-images/{image_path}`; nil without both.
    public static func url(imagePath: String?, supabaseURL: URL?) -> URL? {
        guard let imagePath, let supabaseURL else { return nil }
        return PublicStorage.url(supabaseURL: supabaseURL, bucket: bucket, path: imagePath)
    }
}

/// A file in a public Storage bucket (bank logos, holding photos). URLSession's shared cache keeps
/// what it fetched, so a photo shown on every row is downloaded once.
public enum PublicStorage {
    /// `{supabaseURL}/storage/v1/object/public/{bucket}/{path}`. A path is one file name: a slash
    /// or `..` (which could reach another bucket) is refused.
    public static func url(supabaseURL: URL, bucket: String, path: String) -> URL? {
        guard !path.isEmpty, !path.contains("/"), !path.contains("..") else { return nil }
        return supabaseURL.appendingPathComponent("storage/v1/object/public/\(bucket)").appendingPathComponent(path)
    }
}

/// A price the server keeps (`metal_prices.quote`). Gold is the Dubai Jewellery Group's retail
/// rate per karat, silver the Dubai retail rate; the spot quotes are kept for reference.
public enum MetalQuote: String, CaseIterable, Identifiable, Hashable, Sendable {
    case gold24k = "gold_24k", gold22k = "gold_22k", gold21k = "gold_21k", gold18k = "gold_18k"
    case goldSpot = "gold_spot", silverRetail = "silver_retail", silverSpot = "silver_spot"

    public var id: String { rawValue }

    /// `"24K"`, `"Silver"`: the price strip's labels.
    public var label: String {
        switch self {
        case .gold24k: "24K"
        case .gold22k: "22K"
        case .gold21k: "21K"
        case .gold18k: "18K"
        case .goldSpot: "Gold spot"
        case .silverRetail: "Silver"
        case .silverSpot: "Silver spot"
        }
    }

    /// The Dubai retail rates the holdings are valued at, in the strip's order.
    public static let retail: [MetalQuote] = [.gold24k, .gold22k, .gold21k, .gold18k, .silverRetail]

    /// The quote from a `prices` key. The decoder's snake-case strategy also rewrites dictionary
    /// keys (`gold_24k` → `gold24k`), so both spellings are matched without underscores or case.
    public init?(wireKey: String) {
        let key = wireKey.replacingOccurrences(of: "_", with: "").lowercased()
        guard let match = Self.allCases.first(where: { $0.rawValue.replacingOccurrences(of: "_", with: "") == key })
        else { return nil }
        self = match
    }
}

/// One price in `holdings_valuation.prices`.
public struct MetalPrice: Decodable, Sendable, Hashable {
    public let aedPerGram: Decimal
    public let asOf: Date
    /// The change since the price 24 hours earlier, in percent (`"-0.13"`); nil without one.
    public let change24hPct: Decimal?
    public let isStale: Bool

    public init(aedPerGram: Decimal, asOf: Date, change24hPct: Decimal? = nil, isStale: Bool = false) {
        self.aedPerGram = aedPerGram
        self.asOf = asOf
        self.change24hPct = change24hPct
        self.isStale = isStale
    }

    // The snake-case strategy capitalises `24h` as a word: `change_24h_pct` arrives as `change24HPct`.
    enum CodingKeys: String, CodingKey { case aedPerGram, asOf, change24hPct = "change24HPct", isStale }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aedPerGram = try c.decode(Decimal.self, forKey: .aedPerGram)
        asOf = try c.decode(Date.self, forKey: .asOf)
        change24hPct = try c.decodeIfPresent(Decimal.self, forKey: .change24hPct)
        isStale = try c.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
    }
}

/// `rpc('holdings_valuation')`: every active holding valued at Dubai retail rates, the totals and
/// the latest prices. Every figure is the server's decimal string; nothing is re-derived here.
public struct HoldingsValuation: Decodable, Sendable, Hashable {
    public let valueAed: Decimal
    /// What was paid for the holdings that have a price; nil when none has a cost.
    public let costAed: Decimal?
    public let gainAed: Decimal?
    /// Percent (`"17.80"`), over the holdings that have both a cost and a price.
    public let gainPct: Decimal?
    public let change24hAed: Decimal?
    /// Every holding has a price.
    public let complete: Bool
    /// Every holding has a cost.
    public let costsComplete: Bool
    public let staleCount: Int
    public let holdingsCount: Int
    public let prices: [MetalQuote: MetalPrice]
    /// Most valuable first.
    public let holdings: [Holding]

    public init(valueAed: Decimal, costAed: Decimal? = nil, gainAed: Decimal? = nil, gainPct: Decimal? = nil,
                change24hAed: Decimal? = nil, complete: Bool = true, costsComplete: Bool = true, staleCount: Int = 0,
                prices: [MetalQuote: MetalPrice] = [:], holdings: [Holding] = []) {
        self.valueAed = valueAed
        self.costAed = costAed
        self.gainAed = gainAed
        self.gainPct = gainPct
        self.change24hAed = change24hAed
        self.complete = complete
        self.costsComplete = costsComplete
        self.staleCount = staleCount
        self.holdingsCount = holdings.count
        self.prices = prices
        self.holdings = holdings
    }

    enum CodingKeys: String, CodingKey {
        case valueAed, costAed, gainAed, gainPct, change24hAed = "change24HAed", complete, costsComplete, staleCount, holdingsCount
        case prices, holdings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        valueAed = try c.decode(Decimal.self, forKey: .valueAed)
        costAed = try c.decodeIfPresent(Decimal.self, forKey: .costAed)
        gainAed = try c.decodeIfPresent(Decimal.self, forKey: .gainAed)
        gainPct = try c.decodeIfPresent(Decimal.self, forKey: .gainPct)
        change24hAed = try c.decodeIfPresent(Decimal.self, forKey: .change24hAed)
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? false
        costsComplete = try c.decodeIfPresent(Bool.self, forKey: .costsComplete) ?? false
        staleCount = try c.decodeIfPresent(Int.self, forKey: .staleCount) ?? 0
        holdings = try c.decodeIfPresent([Holding].self, forKey: .holdings) ?? []
        holdingsCount = try c.decodeIfPresent(Int.self, forKey: .holdingsCount) ?? holdings.count
        let raw = try c.decodeIfPresent([String: MetalPrice].self, forKey: .prices) ?? [:]
        var prices: [MetalQuote: MetalPrice] = [:]
        for (key, price) in raw { if let quote = MetalQuote(wireKey: key) { prices[quote] = price } }
        self.prices = prices
    }
}


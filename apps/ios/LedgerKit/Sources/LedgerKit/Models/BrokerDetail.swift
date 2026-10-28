import Foundation

// Zerodha Kite and Coin in detail (`20261028062806_zerodha_position_detail.sql`, tasks/todo.md
// §14): what a position is and how it moved today, where the account's money sits, what stands
// out, Coin's SIPs, and one position over time. Every figure is the server's decimal string;
// `BrokerDetailPresentation` words it. Absent on an older server and for other brokers.

/// A position's detail fields (decoded from the same object as `BrokerPortfolio.Position`).
public struct BrokerPositionFields: Decodable, Sendable, Hashable {
    /// `stock`, `etf` or `fund`; raw, nil when the broker doesn't say.
    public let assetClass: String?
    /// A fund's scheme type: Equity, Debt, Hybrid, …
    public let category: String?
    /// A fund's fund house.
    public let issuer: String?
    public let exchange: String?
    public let folio: String?
    /// The day the price is for (a fund's NAV date).
    public let priceDate: CalendarDay?
    /// The previous close, or a fund's previous NAV.
    public let prevPrice: Decimal?
    /// The average price paid per unit.
    public let costPrice: Decimal?
    /// Today's move against the previous price; nil when unknown.
    public let dayChange: Decimal?
    public let dayChangePct: Decimal?
    /// Its share of the account's positions, in %.
    public let weightPct: Decimal?
    /// Its return on cost, in %.
    public let returnPct: Decimal?

    enum CodingKeys: String, CodingKey {
        case assetClass, category, issuer, exchange, folio, priceDate, prevPrice, costPrice
        case dayChange, dayChangePct, weightPct, returnPct
    }

    public init(assetClass: String? = nil, category: String? = nil, issuer: String? = nil, exchange: String? = nil,
                folio: String? = nil, priceDate: CalendarDay? = nil, prevPrice: Decimal? = nil, costPrice: Decimal? = nil,
                dayChange: Decimal? = nil, dayChangePct: Decimal? = nil, weightPct: Decimal? = nil, returnPct: Decimal? = nil) {
        self.assetClass = assetClass
        self.category = category
        self.issuer = issuer
        self.exchange = exchange
        self.folio = folio
        self.priceDate = priceDate
        self.prevPrice = prevPrice
        self.costPrice = costPrice
        self.dayChange = dayChange
        self.dayChangePct = dayChangePct
        self.weightPct = weightPct
        self.returnPct = returnPct
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetClass = try c.decodeIfPresent(String.self, forKey: .assetClass)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer)
        exchange = try c.decodeIfPresent(String.self, forKey: .exchange)
        folio = try c.decodeIfPresent(String.self, forKey: .folio)
        priceDate = try c.decodeIfPresent(CalendarDay.self, forKey: .priceDate)
        prevPrice = try c.decodeIfPresent(Decimal.self, forKey: .prevPrice)
        costPrice = try c.decodeIfPresent(Decimal.self, forKey: .costPrice)
        dayChange = try c.decodeIfPresent(Decimal.self, forKey: .dayChange)
        dayChangePct = try c.decodeIfPresent(Decimal.self, forKey: .dayChangePct)
        weightPct = try c.decodeIfPresent(Decimal.self, forKey: .weightPct)
        returnPct = try c.decodeIfPresent(Decimal.self, forKey: .returnPct)
    }
}

/// Where the money sits: stocks, ETFs, a fund's scheme type (largest first).
public struct BrokerAllocationSlice: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let positions: Decimal?
    public let value: Decimal?
    public let weightPct: Decimal?
    public let invested: Decimal?
    public let profit: Decimal?
    public let returnPct: Decimal?
}

/// Funds by fund house (largest first).
public struct BrokerIssuerSlice: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { issuer }
    public let issuer: String
    public let positions: Decimal?
    public let value: Decimal?
    public let weightPct: Decimal?
}

/// The best and worst by return, today's biggest moves, and the five largest positions' share.
public struct BrokerHighlights: Decodable, Sendable, Hashable {
    public struct Item: Decodable, Sendable, Hashable {
        public let isin: String?
        public let name: String
        public let returnPct: Decimal?
        public let dayChange: Decimal?
        public let dayChangePct: Decimal?
    }

    public let best: [Item]
    public let worst: [Item]
    public let gainersToday: [Item]
    public let losersToday: [Item]
    public let top5WeightPct: Decimal?

    enum CodingKeys: String, CodingKey {
        case best, worst, gainersToday = "gainers_today", losersToday = "losers_today", top5WeightPct = "top5_weight_pct"
    }

    public init(from decoder: any Decoder) throws {
        let c = try WireKeyedContainer(decoder, keyedBy: CodingKeys.self)
        best = try c.decodeIfPresent([Item].self, forKey: .best) ?? []
        worst = try c.decodeIfPresent([Item].self, forKey: .worst) ?? []
        gainersToday = try c.decodeIfPresent([Item].self, forKey: .gainersToday) ?? []
        losersToday = try c.decodeIfPresent([Item].self, forKey: .losersToday) ?? []
        top5WeightPct = try c.decodeIfPresent(Decimal.self, forKey: .top5WeightPct)
    }
}

/// A Coin SIP as Zerodha reports it, with its latest instalment's outcome.
public struct BrokerSip: Decodable, Sendable, Hashable, Identifiable {
    public struct LastOrder: Decodable, Sendable, Hashable {
        /// `open`, `complete`, `rejected`, `cancelled`.
        public let status: String
        public let message: String?
        public let at: Date?
    }

    public var id: String { sipCode }
    public let sipCode: String
    public let isin: String
    public let fund: String
    /// `active`, `paused`, `cancelled`, `other`.
    public let status: String
    public let frequency: String?
    public let amount: Decimal?
    public let currency: String
    public let day: Decimal?
    public let nextInstalment: CalendarDay?
    public let completed: Decimal?
    /// Zerodha's step-up: `{"10-02": 3}` is 3% more each year from 2 Oct.
    public let stepUp: [String: Decimal]?
    public let lastOrder: LastOrder?
    /// The latest instalment was rejected.
    public let missed: Bool

    enum CodingKeys: String, CodingKey {
        case sipCode, isin, fund, status, frequency, amount, currency, day, nextInstalment, completed, stepUp, lastOrder, missed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sipCode = try c.decode(String.self, forKey: .sipCode)
        isin = try c.decodeIfPresent(String.self, forKey: .isin) ?? ""
        fund = try c.decode(String.self, forKey: .fund)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "other"
        frequency = try c.decodeIfPresent(String.self, forKey: .frequency)
        amount = try c.decodeIfPresent(Decimal.self, forKey: .amount)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "INR"
        day = try c.decodeIfPresent(Decimal.self, forKey: .day)
        nextInstalment = try c.decodeIfPresent(CalendarDay.self, forKey: .nextInstalment)
        completed = try c.decodeIfPresent(Decimal.self, forKey: .completed)
        // Each rate arrives as a decimal string ({"10-02": "3"}); a dictionary's values don't go
        // through the container's string-to-Decimal reading, so they are parsed here.
        stepUp = (try? c.decodeIfPresent([String: String].self, forKey: .stepUp))?.compactMapValues(LedgerDecimal.parse)
            ?? (try? c.decodeIfPresent([String: Decimal].self, forKey: .stepUp))
        lastOrder = try? c.decodeIfPresent(LastOrder.self, forKey: .lastOrder)
        missed = try c.decodeIfPresent(Bool.self, forKey: .missed) ?? false
    }
}

/// The account-level detail of `broker_portfolio` (decoded from the same object).
public struct BrokerPortfolioDetail: Decodable, Sendable, Hashable {
    /// Today's move of the positions with a previous price; nil without one.
    public let dayChange: Decimal?
    public let dayChangePct: Decimal?
    public let allocation: [BrokerAllocationSlice]
    public let issuers: [BrokerIssuerSlice]
    public let highlights: BrokerHighlights?
    public let sips: [BrokerSip]

    enum CodingKeys: String, CodingKey { case dayChange, dayChangePct, allocation, issuers, highlights, sips }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayChange = try c.decodeIfPresent(Decimal.self, forKey: .dayChange)
        dayChangePct = try c.decodeIfPresent(Decimal.self, forKey: .dayChangePct)
        allocation = (try? c.decodeIfPresent([BrokerAllocationSlice].self, forKey: .allocation)) ?? []
        issuers = (try? c.decodeIfPresent([BrokerIssuerSlice].self, forKey: .issuers)) ?? []
        highlights = try? c.decodeIfPresent(BrokerHighlights.self, forKey: .highlights)
        sips = (try? c.decodeIfPresent([BrokerSip].self, forKey: .sips)) ?? []
    }
}

/// `rpc('broker_position_detail')`: one position by ISIN, as the account shows it (nil once no
/// longer held), its marks over time and its SIPs. Null when the account never marked it.
public struct BrokerPositionDetail: Decodable, Sendable, Hashable {
    public struct Mark: Decodable, Sendable, Hashable, Identifiable {
        public var id: CalendarDay { asOf }
        public let asOf: CalendarDay
        public let price: Decimal?
        public let quantity: Decimal?
        public let value: Decimal?
        public let cost: Decimal?
    }

    public let accountCode: String
    public let isin: String
    public let holdingCode: String?
    public let name: String
    public let currency: String
    public let lastMarkedOn: CalendarDay?
    public let position: BrokerPortfolio.Position?
    public let series: [Mark]
    public let sips: [BrokerSip]

    enum CodingKeys: String, CodingKey { case accountCode, isin, holdingCode, name, currency, lastMarkedOn, position, series, sips }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountCode = try c.decode(String.self, forKey: .accountCode)
        isin = try c.decode(String.self, forKey: .isin)
        holdingCode = try c.decodeIfPresent(String.self, forKey: .holdingCode)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? isin
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "INR"
        lastMarkedOn = try c.decodeIfPresent(CalendarDay.self, forKey: .lastMarkedOn)
        position = try? c.decodeIfPresent(BrokerPortfolio.Position.self, forKey: .position)
        series = (try c.decodeIfPresent([Mark].self, forKey: .series) ?? []).sorted { $0.asOf < $1.asOf }
        sips = (try? c.decodeIfPresent([BrokerSip].self, forKey: .sips)) ?? []
    }

    /// The RPC's body: the position, or nil for `null` or an empty body.
    public static func decode(_ data: Data) throws -> BrokerPositionDetail? {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return nil }
        return try LedgerJSON.decode(BrokerPositionDetail.self, from: data)
    }
}

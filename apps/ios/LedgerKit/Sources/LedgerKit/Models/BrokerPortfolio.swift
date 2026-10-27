import Foundation

/// `rpc('broker_portfolio')` (`20261027165732_swissquote_sync.sql`): a synced broker account (the
/// Swissquote account): cash, the latest marks of every position with what it cost and has paid,
/// for a note what it fetches sold today against what it pays if called at its next autocall
/// date, the positions that ended with their result, the value per day against the net deposits,
/// and how the last sync went. Null from the server when the account has no sync. Every figure is
/// the server's decimal string; `BrokerPortfolioPresentation` words it.
public struct BrokerPortfolio: Decodable, Sendable, Hashable {
    /// How the last sync went (`broker_connections.last_*`).
    public struct Sync: Decodable, Sendable, Hashable {
        public let lastSyncedAt: Date?
        public let lastAttemptAt: Date?
        /// `ok`, `error`, or null before the first attempt; kept raw, read by the presentation.
        public let status: String?
        public let error: String?

        public init(lastSyncedAt: Date? = nil, lastAttemptAt: Date? = nil, status: String? = nil, error: String? = nil) {
            self.lastSyncedAt = lastSyncedAt
            self.lastAttemptAt = lastAttemptAt
            self.status = status
            self.error = error
        }
    }

    /// Sold today at the broker's bid, with what the position has paid so far, against what went in.
    public struct SellNow: Decodable, Sendable, Hashable {
        public let total: Decimal
        public let profit: Decimal
        public let returnPct: Decimal
    }

    /// A position that is a structured note: the evaluator's view of it today.
    public struct Note: Decodable, Sendable, Hashable {
        /// Raw; `noteStatus` reads it (an unknown one reads as live).
        public let status: String?
        public let next: NoteNext?
        /// The first autocall scenario: what it pays if called at its next autocall date.
        public let ifCalledNext: NoteDetail.AutocallScenario?
        public let ifEndedToday: NoteSummary.IfEndedToday?
        public let worstNow: NoteSummary.Worst?
        public let awaitingPrices: Bool?
        /// Each share against its initial level and the next autocall (absent on an older server).
        public let underlyings: [NoteDetail.Underlying]?

        public var noteStatus: NoteStatus { NoteStatus(raw: status) }
    }

    /// One position at the latest mark.
    public struct Position: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { holdingCode }
        public let holdingCode: String
        /// `structured_note`, `broker` (a note the ledger has no terms for) or `security`; an
        /// unknown kind reads as a broker holding (`HoldingKind`).
        public let kind: HoldingKind
        public let name: String
        public let isin: String?
        /// The broker's own name for it.
        public let securityName: String?
        public let symbol: String?
        public let productType: String?
        public let quantity: Decimal?
        public let price: Decimal?
        /// The price is a % of the nominal (bonds and notes), not a unit price.
        public let priceInPct: Bool
        public let currency: String
        public let value: Decimal?
        public let valueAed: Decimal?
        public let asOf: CalendarDay?
        public let cost: Decimal?
        /// The broker's own P&L: the value against its cost price.
        public let profit: Decimal?
        public let invested: Decimal
        public let income: Decimal
        public let sellNow: SellNow?
        public let note: Note?

        enum CodingKeys: String, CodingKey {
            case holdingCode, kind, name, isin, securityName, symbol, productType, quantity, price, priceInPct
            case currency, value, valueAed, asOf, cost, profit, invested, income, sellNow, note
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            holdingCode = try c.decode(String.self, forKey: .holdingCode)
            kind = try c.decodeIfPresent(HoldingKind.self, forKey: .kind) ?? .broker
            name = try c.decode(String.self, forKey: .name)
            isin = try c.decodeIfPresent(String.self, forKey: .isin)
            securityName = try c.decodeIfPresent(String.self, forKey: .securityName)
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
            productType = try c.decodeIfPresent(String.self, forKey: .productType)
            quantity = try c.decodeIfPresent(Decimal.self, forKey: .quantity)
            price = try c.decodeIfPresent(Decimal.self, forKey: .price)
            priceInPct = try c.decodeIfPresent(Bool.self, forKey: .priceInPct) ?? false
            currency = try c.decode(String.self, forKey: .currency)
            value = try c.decodeIfPresent(Decimal.self, forKey: .value)
            valueAed = try c.decodeIfPresent(Decimal.self, forKey: .valueAed)
            asOf = try c.decodeIfPresent(CalendarDay.self, forKey: .asOf)
            cost = try c.decodeIfPresent(Decimal.self, forKey: .cost)
            profit = try c.decodeIfPresent(Decimal.self, forKey: .profit)
            invested = try c.decodeIfPresent(Decimal.self, forKey: .invested) ?? 0
            income = try c.decodeIfPresent(Decimal.self, forKey: .income) ?? 0
            sellNow = try c.decodeIfPresent(SellNow.self, forKey: .sellNow)
            note = try c.decodeIfPresent(Note.self, forKey: .note)
        }
    }

    /// A position that ended (sold, called, matured), with its result.
    public struct ClosedPosition: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { holdingCode }
        public let holdingCode: String
        public let kind: HoldingKind
        public let name: String
        public let isin: String?
        public let invested: Decimal
        public let returned: Decimal
        public let income: Decimal
        public let profit: Decimal
        public let returnPct: Decimal?
        public let annualisedPct: Decimal?
        public let openedOn: CalendarDay?
        public let closedOn: CalendarDay?
        /// The note's status when it was a structured note (`autocalled`, `matured`); raw.
        public let noteStatus: String?

        enum CodingKeys: String, CodingKey {
            case holdingCode, kind, name, isin, invested, returned, income, profit, returnPct, annualisedPct
            case openedOn, closedOn, noteStatus
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            holdingCode = try c.decode(String.self, forKey: .holdingCode)
            kind = try c.decodeIfPresent(HoldingKind.self, forKey: .kind) ?? .broker
            name = try c.decode(String.self, forKey: .name)
            isin = try c.decodeIfPresent(String.self, forKey: .isin)
            invested = try c.decode(Decimal.self, forKey: .invested)
            returned = try c.decode(Decimal.self, forKey: .returned)
            income = try c.decodeIfPresent(Decimal.self, forKey: .income) ?? 0
            profit = try c.decode(Decimal.self, forKey: .profit)
            returnPct = try c.decodeIfPresent(Decimal.self, forKey: .returnPct)
            annualisedPct = try c.decodeIfPresent(Decimal.self, forKey: .annualisedPct)
            openedOn = try c.decodeIfPresent(CalendarDay.self, forKey: .openedOn)
            closedOn = try c.decodeIfPresent(CalendarDay.self, forKey: .closedOn)
            noteStatus = try c.decodeIfPresent(String.self, forKey: .noteStatus)
        }
    }

    /// One day's value against the money put in to date. `estimated` days were rebuilt from the
    /// broker's performance index (before daily syncs began) and carry no cash/positions split.
    public struct Point: Decodable, Sendable, Hashable, Identifiable {
        public var id: CalendarDay { asOf }
        public let asOf: CalendarDay
        public let total: Decimal
        public let cash: Decimal?
        public let positions: Decimal?
        public let netDeposits: Decimal
        public let estimated: Bool

        public init(asOf: CalendarDay, total: Decimal, cash: Decimal? = nil, positions: Decimal? = nil,
                    netDeposits: Decimal, estimated: Bool) {
            self.asOf = asOf
            self.total = total
            self.cash = cash
            self.positions = positions
            self.netDeposits = netDeposits
            self.estimated = estimated
        }

        enum CodingKeys: String, CodingKey { case asOf, total, cash, positions, netDeposits, estimated }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            asOf = try c.decode(CalendarDay.self, forKey: .asOf)
            total = try c.decode(Decimal.self, forKey: .total)
            cash = try c.decodeIfPresent(Decimal.self, forKey: .cash)
            positions = try c.decodeIfPresent(Decimal.self, forKey: .positions)
            netDeposits = try c.decodeIfPresent(Decimal.self, forKey: .netDeposits) ?? 0
            estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
        }
    }

    public let accountCode: String
    /// `swissquote`; raw (a provider this build doesn't know is shown by its name).
    public let provider: String
    public let portfolioRef: String?
    public let currency: String
    public let sync: Sync
    /// The day of the latest marks; nil before the first positions arrive.
    public let asOf: CalendarDay?
    public let cash: Decimal?
    public let positionsValue: Decimal
    public let total: Decimal
    public let totalAed: Decimal?
    public let netDeposits: Decimal
    public let profit: Decimal
    public let income: Decimal
    public let fees: Decimal
    public let positions: [Position]
    public let closed: [ClosedPosition]
    public let series: [Point]

    enum CodingKeys: String, CodingKey {
        case accountCode, provider, portfolioRef, currency, sync, asOf, cash, positionsValue, total, totalAed
        case netDeposits, profit, income, fees, positions, closed, series
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountCode = try c.decode(String.self, forKey: .accountCode)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "broker"
        portfolioRef = try c.decodeIfPresent(String.self, forKey: .portfolioRef)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        sync = try c.decodeIfPresent(Sync.self, forKey: .sync) ?? Sync()
        asOf = try c.decodeIfPresent(CalendarDay.self, forKey: .asOf)
        cash = try c.decodeIfPresent(Decimal.self, forKey: .cash)
        positionsValue = try c.decodeIfPresent(Decimal.self, forKey: .positionsValue) ?? 0
        total = try c.decode(Decimal.self, forKey: .total)
        totalAed = try c.decodeIfPresent(Decimal.self, forKey: .totalAed)
        netDeposits = try c.decodeIfPresent(Decimal.self, forKey: .netDeposits) ?? 0
        profit = try c.decode(Decimal.self, forKey: .profit)
        income = try c.decodeIfPresent(Decimal.self, forKey: .income) ?? 0
        fees = try c.decodeIfPresent(Decimal.self, forKey: .fees) ?? 0
        positions = try c.decodeIfPresent([Position].self, forKey: .positions) ?? []
        closed = try c.decodeIfPresent([ClosedPosition].self, forKey: .closed) ?? []
        series = try c.decodeIfPresent([Point].self, forKey: .series) ?? []
    }

    /// The RPC's body: the portfolio, or nil for `null` (an account with no sync) or an empty body.
    public static func decode(_ data: Data) throws -> BrokerPortfolio? {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return nil }
        return try LedgerJSON.decode(BrokerPortfolio.self, from: data)
    }
}

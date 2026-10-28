import Foundation

/// `rpc('india_overview')`: India mode's one read. Every Zerodha Kite and Coin account in rupees
/// (cash + positions, cost, unrealised P&L, the last 24 hours), each account on its own line, and
/// for one period the value against what was invested day by day and what it grew by. Wealth
/// leaves these accounts out entirely. Every figure is the server's decimal string (INR unless
/// `…Aed`); counts arrive as strings too. Decoding is tolerant: a missing figure is nil, never a
/// failed screen.
public struct IndiaOverview: Decodable, Sendable, Hashable {
    /// False for a ledger with no India account: India mode isn't offered.
    public let available: Bool
    public let currency: String
    /// Raw (`"90d"`).
    public let period: String
    public let from: CalendarDay?
    public let to: CalendarDay?
    public let total: Total
    /// Kite first, then Coin.
    public let accounts: [Account]
    /// One point per day from `from` to `to` that has data, oldest first.
    public let series: [Point]

    public struct Total: Decodable, Sendable, Hashable {
        /// Cash + positions, every India account.
        public let value: Decimal?
        public let valueAed: Decimal?
        /// The cost of the open positions.
        public let invested: Decimal?
        public let cash: Decimal?
        /// Positions value − invested.
        public let pnl: Decimal?
        public let pnlPct: Decimal?
        /// The open positions' day move against each one's previous mark; nil without two marks.
        public let change24h: Decimal?
        public let change24hAed: Decimal?
        public let change24hPct: Decimal?
        public let periodStartValue: Decimal?
        public let periodEndValue: Decimal?
        /// Change in invested over the period (money put in, at cost).
        public let periodAdded: Decimal?
        /// (end − start) − added.
        public let periodGrowth: Decimal?
        public let periodGrowthPct: Decimal?
        public let positions: Int
        public let lastSyncedAt: Date?

        public init(value: Decimal? = nil, valueAed: Decimal? = nil, invested: Decimal? = nil, cash: Decimal? = nil,
                    pnl: Decimal? = nil, pnlPct: Decimal? = nil, change24h: Decimal? = nil,
                    change24hAed: Decimal? = nil, change24hPct: Decimal? = nil, periodStartValue: Decimal? = nil,
                    periodEndValue: Decimal? = nil, periodAdded: Decimal? = nil, periodGrowth: Decimal? = nil,
                    periodGrowthPct: Decimal? = nil, positions: Int = 0, lastSyncedAt: Date? = nil) {
            self.value = value
            self.valueAed = valueAed
            self.invested = invested
            self.cash = cash
            self.pnl = pnl
            self.pnlPct = pnlPct
            self.change24h = change24h
            self.change24hAed = change24hAed
            self.change24hPct = change24hPct
            self.periodStartValue = periodStartValue
            self.periodEndValue = periodEndValue
            self.periodAdded = periodAdded
            self.periodGrowth = periodGrowth
            self.periodGrowthPct = periodGrowthPct
            self.positions = positions
            self.lastSyncedAt = lastSyncedAt
        }

        // The decoder's snake-case strategy reads `change_24h_pct` as `change24HPct`.
        enum CodingKeys: String, CodingKey {
            case value, valueAed, invested, cash, pnl, pnlPct, positions, lastSyncedAt
            case periodStartValue, periodEndValue, periodAdded, periodGrowth, periodGrowthPct
            case change24h = "change24H", change24hAed = "change24HAed", change24hPct = "change24HPct"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func d(_ key: CodingKeys) throws -> Decimal? { try c.decodeIfPresent(Decimal.self, forKey: key) }
            value = try d(.value)
            valueAed = try d(.valueAed)
            invested = try d(.invested)
            cash = try d(.cash)
            pnl = try d(.pnl)
            pnlPct = try d(.pnlPct)
            change24h = try d(.change24h)
            change24hAed = try d(.change24hAed)
            change24hPct = try d(.change24hPct)
            periodStartValue = try d(.periodStartValue)
            periodEndValue = try d(.periodEndValue)
            periodAdded = try d(.periodAdded)
            periodGrowth = try d(.periodGrowth)
            periodGrowthPct = try d(.periodGrowthPct)
            positions = IndiaOverview.count(try d(.positions))
            lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        }
    }

    public struct Account: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { accountCode }
        public let accountCode: String
        public let bankCode: String?
        public let name: String
        /// Raw (`kite`, `coin`); one this build doesn't know opens no tab.
        public let segment: String?
        public let value: Decimal?
        public let valueAed: Decimal?
        public let invested: Decimal?
        public let cash: Decimal?
        public let pnl: Decimal?
        public let pnlPct: Decimal?
        public let change24h: Decimal?
        public let change24hPct: Decimal?
        public let positions: Int
        public let lastSyncedAt: Date?
        /// `ok`, `error` or null; raw.
        public let syncStatus: String?

        public init(accountCode: String, bankCode: String? = nil, name: String, segment: String? = nil,
                    value: Decimal? = nil, valueAed: Decimal? = nil, invested: Decimal? = nil, cash: Decimal? = nil,
                    pnl: Decimal? = nil, pnlPct: Decimal? = nil, change24h: Decimal? = nil,
                    change24hPct: Decimal? = nil, positions: Int = 0, lastSyncedAt: Date? = nil,
                    syncStatus: String? = nil) {
            self.accountCode = accountCode
            self.bankCode = bankCode
            self.name = name
            self.segment = segment
            self.value = value
            self.valueAed = valueAed
            self.invested = invested
            self.cash = cash
            self.pnl = pnl
            self.pnlPct = pnlPct
            self.change24h = change24h
            self.change24hPct = change24hPct
            self.positions = positions
            self.lastSyncedAt = lastSyncedAt
            self.syncStatus = syncStatus
        }

        enum CodingKeys: String, CodingKey {
            case accountCode, bankCode, name, segment, value, valueAed, invested, cash, pnl, pnlPct
            case positions, lastSyncedAt, syncStatus
            case change24h = "change24H", change24hPct = "change24HPct"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func d(_ key: CodingKeys) throws -> Decimal? { try c.decodeIfPresent(Decimal.self, forKey: key) }
            accountCode = try c.decode(String.self, forKey: .accountCode)
            bankCode = try c.decodeIfPresent(String.self, forKey: .bankCode)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Zerodha"
            segment = try c.decodeIfPresent(String.self, forKey: .segment)
            value = try d(.value)
            valueAed = try d(.valueAed)
            invested = try d(.invested)
            cash = try d(.cash)
            pnl = try d(.pnl)
            pnlPct = try d(.pnlPct)
            change24h = try d(.change24h)
            change24hPct = try d(.change24hPct)
            positions = IndiaOverview.count(try d(.positions))
            lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
            syncStatus = try c.decodeIfPresent(String.self, forKey: .syncStatus)
        }

        /// The India tab that shows this account's portfolio: Kite or Coin by segment, else by
        /// bank (ZRD, the account from before Kite and Coin were split, is Kite's); nil otherwise.
        public var tab: LedgerTab? {
            switch segment?.lowercased() {
            case "kite": return .kite
            case "coin": return .coin
            default: break
            }
            switch bankCode?.uppercased() {
            case "KITE", "ZRD": return .kite
            case "COIN": return .coin
            default: return nil
            }
        }
    }

    public struct Point: Decodable, Sendable, Hashable, Identifiable {
        public var id: CalendarDay { date }
        public let date: CalendarDay
        public let value: Decimal?
        public let invested: Decimal?

        public init(date: CalendarDay, value: Decimal?, invested: Decimal?) {
            self.date = date
            self.value = value
            self.invested = invested
        }
    }

    public init(available: Bool, currency: String = "INR", period: ReturnsPeriod = .ninetyDays,
                from: CalendarDay? = nil, to: CalendarDay? = nil, total: Total = Total(),
                accounts: [Account] = [], series: [Point] = []) {
        self.available = available
        self.currency = currency
        self.period = period.rawValue
        self.from = from
        self.to = to
        self.total = total
        self.accounts = accounts
        self.series = series
    }

    enum CodingKeys: String, CodingKey { case available, currency, period, from, to, total, accounts, series }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "INR"
        period = try c.decodeIfPresent(String.self, forKey: .period) ?? ReturnsPeriod.ninetyDays.rawValue
        from = try c.decodeIfPresent(CalendarDay.self, forKey: .from)
        to = try c.decodeIfPresent(CalendarDay.self, forKey: .to)
        total = try c.decodeIfPresent(Total.self, forKey: .total) ?? Total()
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        series = (try c.decodeIfPresent([Point].self, forKey: .series) ?? []).sorted { $0.date < $1.date }
    }

    static func count(_ value: Decimal?) -> Int { NSDecimalNumber(decimal: value ?? 0).intValue }

    /// India's tab bar for this ledger: Overview, then Kite and/or Coin for the accounts it has;
    /// empty when India isn't available.
    public var tabs: [LedgerTab] {
        guard available else { return [] }
        let accountTabs = Set(accounts.compactMap(\.tab))
        return [.overview] + [LedgerTab.kite, .coin].filter(accountTabs.contains)
    }

    /// The account a Kite or Coin tab shows (the first, when there were ever two).
    public func account(for tab: LedgerTab) -> Account? { accounts.first { $0.tab == tab } }
}

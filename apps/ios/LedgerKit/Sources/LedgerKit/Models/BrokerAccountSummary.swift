import Foundation

/// One synced broker account in `broker_accounts_summary` (20261027200000): its value, profit and
/// live notes, and the holdings it already shows (`holdingCodes`), which Investments then leaves
/// out of its own lists. Every figure is the server's decimal string; counts arrive as strings too.
public struct BrokerAccountSummary: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    /// Raw (`swissquote`); a provider this build doesn't know is shown by `name`.
    public let provider: String?
    public let bankCode: String?
    public let name: String
    public let currency: String
    public let cash: Decimal?
    public let positionsValue: Decimal?
    public let total: Decimal
    public let totalAed: Decimal?
    public let netDeposits: Decimal?
    public let profit: Decimal?
    /// The profit in AED (20261028…); nil from an older server.
    public let profitAed: Decimal?
    /// The open positions' market move since the previous day's marks, in the account's currency
    /// and AED, and in percent; nil without two days of marks (or from an older server).
    public let change24h: Decimal?
    public let change24hAed: Decimal?
    public let change24hPct: Decimal?
    public let liveNotes: Int
    public let positions: Int
    public let lastSyncedAt: Date?
    /// `ok`, `error` or null; raw.
    public let syncStatus: String?
    public let holdingCodes: [String]

    enum CodingKeys: String, CodingKey {
        case accountCode, provider, bankCode, name, currency, cash, positionsValue, total, totalAed, netDeposits
        case profit, liveNotes, positions, lastSyncedAt, syncStatus, holdingCodes
        case profitAed, change24h = "change24H", change24hAed = "change24HAed", change24hPct = "change24HPct"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int {
            NSDecimalNumber(decimal: try c.decodeIfPresent(Decimal.self, forKey: key) ?? 0).intValue
        }
        accountCode = try c.decode(String.self, forKey: .accountCode)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        bankCode = try c.decodeIfPresent(String.self, forKey: .bankCode)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Broker account"
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        cash = try c.decodeIfPresent(Decimal.self, forKey: .cash)
        positionsValue = try c.decodeIfPresent(Decimal.self, forKey: .positionsValue)
        total = try c.decodeIfPresent(Decimal.self, forKey: .total) ?? 0
        totalAed = try c.decodeIfPresent(Decimal.self, forKey: .totalAed)
        netDeposits = try c.decodeIfPresent(Decimal.self, forKey: .netDeposits)
        profit = try c.decodeIfPresent(Decimal.self, forKey: .profit)
        profitAed = try c.decodeIfPresent(Decimal.self, forKey: .profitAed)
        change24h = try c.decodeIfPresent(Decimal.self, forKey: .change24h)
        change24hAed = try c.decodeIfPresent(Decimal.self, forKey: .change24hAed)
        change24hPct = try c.decodeIfPresent(Decimal.self, forKey: .change24hPct)
        liveNotes = try count(.liveNotes)
        positions = try count(.positions)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        syncStatus = try c.decodeIfPresent(String.self, forKey: .syncStatus)
        holdingCodes = try c.decodeIfPresent([String].self, forKey: .holdingCodes) ?? []
    }
}

/// A synced broker account at the top of Investments, standing in for every holding it shows:
/// `"Swissquote"`, `"AED 417,256"` with `"USD 113,616"` under it, `"+AED 68,371 · 5 live notes"`
/// and the 24-hour move. AED leads, like every other investment; the account's own currency is
/// second. Opens the account's portfolio.
public struct BrokerAccountRow: Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    public let bankCode: String?
    public let title: String
    /// `"AED 417,256"`; the account's own currency when there is no AED value yet.
    public let valueText: String
    /// `"USD 113,616"` under the AED value, for an account outside AED; nil otherwise.
    public let ownText: String?
    public let detail: String
    public let profitTone: Tone
    /// `"+AED 1,204 (+0.29%) in 24h"`; nil without a move.
    public let changeText: String?
    public let changeTone: Tone
    /// The last sync failed.
    public let syncFailed: Bool

    public init(_ a: BrokerAccountSummary) {
        accountCode = a.accountCode
        bankCode = a.bankCode
        title = a.name
        let own = NoteText.whole(a.total, currency: a.currency)
        if a.currency != "AED", let aed = a.totalAed {
            valueText = MoneyFormat.aed(aed, fractionDigits: 0)
            ownText = own
        } else {
            valueText = own
            ownText = nil
        }
        let notes = a.liveNotes == 1 ? "1 live note" : "\(a.liveNotes) live notes"
        let profit = a.currency == "AED" ? a.profit.map { NoteText.signedWhole($0, currency: "AED") }
            : (a.profitAed.map { NoteText.signedWhole($0, currency: "AED") }
               ?? a.profit.map { NoteText.signedWhole($0, currency: a.currency) })
        detail = ([profit, a.liveNotes > 0 ? notes : nil, a.syncStatus == "error" ? "last sync failed" : nil]
            .compactMap { $0 })
            .joined(separator: " · ")
        profitTone = NoteText.profitTone(a.profitAed ?? a.profit)
        let move = a.currency == "AED" ? a.change24h : a.change24hAed
        if let move, MoneyFormat.rounded(move, scale: 0) != 0 {
            changeText = NoteText.signedWhole(move, currency: "AED")
                + (a.change24hPct.map { " (\(HoldingsText.signedPercent($0)))" } ?? "") + " in 24h"
        } else {
            changeText = nil
        }
        changeTone = NoteText.profitTone(move.flatMap { MoneyFormat.rounded($0, scale: 0) == 0 ? nil : $0 })
        syncFailed = a.syncStatus == "error"
    }

    /// For VoiceOver.
    public var accessibilityLabel: String {
        [title, valueText, ownText, detail, changeText].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What Investments lists: one row per synced broker account, then the holdings by kind without
/// the ones those accounts already show, and the live notes held anywhere else.
public struct InvestmentsLayout: Sendable, Hashable {
    public let brokerRows: [BrokerAccountRow]
    public let groups: [HoldingGroup]
    /// Every holding code a broker account shows.
    public let brokerHoldings: Set<String>

    public init(valuation: HoldingsValuation, brokerAccounts: [BrokerAccountSummary]) {
        brokerRows = brokerAccounts.map(BrokerAccountRow.init)
        brokerHoldings = Set(brokerAccounts.flatMap(\.holdingCodes))
        let shown = brokerHoldings
        groups = HoldingGroup.groups(valuation.holdings.filter { !shown.contains($0.holdingCode) })
    }

    /// Nothing to list at all: no broker account and no holding outside the notes card.
    public var isEmpty: Bool { brokerRows.isEmpty && groups.isEmpty }

    /// The live notes Investments lists itself: those no synced broker account shows.
    public func notes(_ all: [NoteSummary], today: CalendarDay = LedgerDates.today()) -> [NoteListRow] {
        NoteListRow.rows(all, excluding: brokerHoldings, today: today)
    }
}

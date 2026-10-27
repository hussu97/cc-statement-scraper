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
    public let liveNotes: Int
    public let positions: Int
    public let lastSyncedAt: Date?
    /// `ok`, `error` or null; raw.
    public let syncStatus: String?
    public let holdingCodes: [String]

    enum CodingKeys: String, CodingKey {
        case accountCode, provider, bankCode, name, currency, cash, positionsValue, total, totalAed, netDeposits
        case profit, liveNotes, positions, lastSyncedAt, syncStatus, holdingCodes
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
        liveNotes = try count(.liveNotes)
        positions = try count(.positions)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        syncStatus = try c.decodeIfPresent(String.self, forKey: .syncStatus)
        holdingCodes = try c.decodeIfPresent([String].self, forKey: .holdingCodes) ?? []
    }
}

/// A synced broker account at the top of Investments, standing in for every holding it shows:
/// `"Swissquote"`, `"USD 113,616"`, `"+USD 18,616 · 5 live notes"`. Opens the account screen.
public struct BrokerAccountRow: Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    public let bankCode: String?
    public let title: String
    public let valueText: String
    /// `"≈ AED 417,256"` for an account outside AED.
    public let aedText: String?
    public let detail: String
    public let profitTone: Tone
    /// The last sync failed.
    public let syncFailed: Bool

    public init(_ a: BrokerAccountSummary) {
        accountCode = a.accountCode
        bankCode = a.bankCode
        title = a.name
        valueText = NoteText.whole(a.total, currency: a.currency)
        aedText = a.currency == "AED" ? nil : a.totalAed.map { "≈ \(MoneyFormat.aed($0, fractionDigits: 0))" }
        let notes = a.liveNotes == 1 ? "1 live note" : "\(a.liveNotes) live notes"
        detail = ([a.profit.map { NoteText.signedWhole($0, currency: a.currency) }].compactMap { $0 }
            + [a.liveNotes > 0 ? notes : nil].compactMap { $0 }
            + [a.syncStatus == "error" ? "last sync failed" : nil].compactMap { $0 })
            .joined(separator: " · ")
        profitTone = NoteText.profitTone(a.profit)
        syncFailed = a.syncStatus == "error"
    }

    /// For VoiceOver.
    public var accessibilityLabel: String { [title, valueText, aedText, detail].compactMap { $0 }.joined(separator: ", ") }
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

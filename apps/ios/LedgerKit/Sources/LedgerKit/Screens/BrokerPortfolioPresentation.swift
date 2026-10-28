import Foundation

/// What a synced broker account's screen shows, worded. Up top, always: three numbers (total
/// value, profit against what was put in, cash), how fresh they are, and the value over time.
/// Then a choice of Portfolio (a card per live note, a line per other holding), Transactions
/// (the account's ledger) and Past notes (what ended, with the total). Against cost (Zerodha):
/// the P&L on what was invested, Kite and Coin one line each, a card per segment, and "Sold".
/// Every figure is the server's (`broker_portfolio`); nothing here adds money up (CLAUDE.md §2.2).
public struct BrokerPortfolioPresentation: Sendable, Hashable {
    public let portfolio: BrokerPortfolio
    public let now: Date

    public init(_ portfolio: BrokerPortfolio, now: Date = .now) {
        self.portfolio = portfolio
        self.now = now
    }

    private var currency: String { portfolio.currency }
    private var byCost: Bool { portfolio.basis == .cost }
    private var today: CalendarDay { LedgerDates.today(now: now) }
    private func whole(_ v: Decimal) -> String { NoteText.whole(v, currency: currency) }

    // MARK: Header

    /// `"Swissquote"`; a provider this build doesn't know by its own name.
    public var providerName: String {
        switch portfolio.provider {
        case "swissquote": "Swissquote"
        case "zerodha": "Zerodha"
        default: portfolio.provider.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The three numbers: total value (≈ AED under it), profit on what was put in (against cost:
    /// the P&L on what was invested), and cash.
    public var figures: [NoteStat] {
        let aed = currency == "AED" ? nil : portfolio.totalAed.map { "≈ \(MoneyFormat.aed($0, fractionDigits: 0))" }
        let on = byCost ? portfolio.invested.map { "on \(whole($0)) invested" } : "on \(whole(portfolio.netDeposits)) put in"
        return [
            NoteStat("Total value", whole(portfolio.total), sub: aed),
            NoteStat(byCost ? "P&L" : "Profit", NoteText.signedWhole(portfolio.profit, currency: currency),
                     sub: on, tone: NoteText.profitTone(portfolio.profit)),
            NoteStat("Cash", portfolio.cash.map(whole) ?? "—", sub: portfolio.cash == nil ? "No cash figure yet" : nil),
        ]
    }

    // MARK: Sync

    public struct SyncLine: Sendable, Hashable {
        public let text: String
        public let tone: Tone
        public let detail: String?
    }

    /// How fresh the figures are, in one small line: `"Synced today, 14:00"`. A failed attempt says
    /// so with the broker's error (warn); a sync two or more days old is late (it runs daily).
    public var sync: SyncLine {
        let s = portfolio.sync
        let lastGood = s.lastSyncedAt.map { CashText.relative($0, now: now) }
        if s.status == "error" {
            let error = s.error.flatMap { $0.isEmpty ? nil : $0 }
            return SyncLine(text: "Last sync failed" + (error.map { ": \($0)" } ?? ""), tone: .warn,
                            detail: lastGood.map { "Last good sync \($0)" })
        }
        guard let synced = s.lastSyncedAt, let lastGood else {
            return SyncLine(text: "Not synced yet", tone: .neutral,
                            detail: "The first sync brings in the positions and their history.")
        }
        let late = CalendarDay(date: synced).days(until: today) >= 2
        return SyncLine(text: "Synced \(lastGood)", tone: late ? .warn : .neutral,
                        detail: late ? "It syncs every day; this one is late." : nil)
    }

    // MARK: Tabs

    /// Portfolio and Transactions always; Past notes once something has ended.
    public var tabs: [BrokerTab] { portfolio.closed.isEmpty ? [.portfolio, .transactions] : BrokerTab.allCases }

    /// `"Portfolio"`, `"Transactions"`, `"Past notes (6)"`.
    public func title(_ tab: BrokerTab) -> String {
        switch tab {
        case .portfolio: "Portfolio"
        case .transactions: "Transactions"
        case .pastNotes: "\(byCost ? "Sold" : "Past notes") (\(portfolio.closed.count))"
        }
    }

    // MARK: Segments (Zerodha)

    /// A line per segment under the three numbers, only when the account has more than one (a
    /// Zerodha account from before Kite and Coin were split). Zerodha Kite and Zerodha Coin are
    /// each one segment, whose line would repeat the figures above it; empty for other brokers.
    public var segments: [BrokerSegmentLine] {
        portfolio.segments.count > 1 ? portfolio.segments.map { BrokerSegmentLine($0, currency: currency) } : []
    }

    /// Against cost, the Portfolio tab is a card per segment (largest value first within each);
    /// empty otherwise, when the tab shows notes and other holdings.
    public var segmentGroups: [BrokerSegmentGroup] { byCost ? BrokerSegmentGroup.groups(sortedPositions) : [] }

    // MARK: Portfolio

    /// "Your notes": one card per live structured note, largest value first.
    public var notes: [BrokerNoteCard] {
        sortedPositions.filter(Self.isLiveNote).map { BrokerNoteCard($0, today: today) }
    }

    /// "Other holdings": everything else (shares, notes the ledger has no terms for), one line each.
    public var otherHoldings: [BrokerHoldingRow] {
        sortedPositions.filter { !Self.isLiveNote($0) }.map { BrokerHoldingRow($0) }
    }

    /// A structured note with terms that hasn't ended.
    static func isLiveNote(_ p: BrokerPortfolio.Position) -> Bool {
        p.kind == .structuredNote && p.note.map { !$0.noteStatus.isEnded } == true
    }

    /// Largest value first, unpriced last, then by name.
    private var sortedPositions: [BrokerPortfolio.Position] {
        portfolio.positions.sorted { a, b in
            switch (a.value, b.value) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Instead of the portfolio's lists.
    public var positionsEmptyMessage: String {
        portfolio.asOf == nil ? "Positions show after the first sync." : "No positions: everything is in cash."
    }

    // MARK: Past notes

    /// `"6 called early · +USD 21,441 earned on USD 98,275"`; nil from an older server or with nothing ended.
    public var pastSummary: String? {
        guard let t = portfolio.closedTotal, t.count > 0 else { return nil }
        let allCalled = !portfolio.closed.isEmpty && portfolio.closed.allSatisfy { $0.noteStatus == "autocalled" }
        let what = "\(t.count) \(allCalled ? "called early" : "ended")"
        let result = t.profit < 0
            ? "\(whole(-t.profit)) lost on \(whole(t.invested))"
            : "\(NoteText.signedWhole(t.profit, currency: currency)) earned on \(whole(t.invested))"
        return "\(what) · \(result)"
    }

    /// The positions that ended, latest first.
    public var past: [BrokerPastRow] {
        portfolio.closed
            .sorted { ($0.closedOn ?? .init(year: 1, month: 1, day: 1)) > ($1.closedOn ?? .init(year: 1, month: 1, day: 1)) }
            .map { BrokerPastRow($0, currency: currency) }
    }

    // MARK: Chart

    public var chart: BrokerValueChart { BrokerValueChart(portfolio.series, currency: currency, basis: portfolio.basis) }
}

/// The account screen's three views of a synced broker account.
public enum BrokerTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    case portfolio, transactions, pastNotes
    public var id: String { rawValue }
}

/// What the account screen shows of the broker portfolio. Every account asks
/// (`broker_portfolio` answers null without a sync), so only a broker account (Swissquote, Zerodha, where
/// the sync runs) shows its loading and failure; any other account shows nothing until a
/// portfolio arrives.
public enum BrokerSection: Sendable, Hashable {
    case hidden
    case loading
    case failed(String)
    case loaded(BrokerPortfolioPresentation)

    /// A synced broker account (loaded or not): its statement lists no notes, which are its portfolio's.
    public var isBroker: Bool { self != .hidden }

    /// The banks whose accounts sync from a broker (Zerodha Kite and Zerodha Coin; ZRD from before they were split).
    public static let brokerBanks: Set<String> = ["SWQ", "ZRD", "KITE", "COIN"]

    public init(_ state: LoadState<BrokerPortfolio?>, bankCode: String?, now: Date = .now) {
        if case .some(.some(let portfolio)) = state.value {
            self = .loaded(BrokerPortfolioPresentation(portfolio, now: now))
            return
        }
        let isBroker = bankCode.map(Self.brokerBanks.contains) ?? false
        switch state {
        case .loading(previous: nil) where isBroker: self = .loading
        case .failed(let message, previous: nil) where isBroker: self = .failed(message)
        default: self = .hidden
        }
    }
}

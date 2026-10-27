import Foundation

/// What a synced broker account's section on the account screen shows, worded: the value now
/// (and in AED), the stat tiles, how the last sync went, the value-over-time chart, the positions
/// (a note's sold-today against if-called side by side) and the positions that ended. Every
/// figure is the server's (`broker_portfolio`); nothing here adds money up (CLAUDE.md §2.2).
public struct BrokerPortfolioPresentation: Sendable, Hashable {
    public let portfolio: BrokerPortfolio
    public let now: Date

    public init(_ portfolio: BrokerPortfolio, now: Date = .now) {
        self.portfolio = portfolio
        self.now = now
    }

    private var currency: String { portfolio.currency }
    private var today: CalendarDay { LedgerDates.today(now: now) }
    private func money(_ v: Decimal) -> String { MoneyFormat.amount(v, currency: currency) }

    // MARK: Header

    /// `"Swissquote"`; a provider this build doesn't know by its own name.
    public var providerName: String {
        switch portfolio.provider {
        case "swissquote": "Swissquote"
        default: portfolio.provider.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The card's title: `"Swissquote portfolio"`.
    public var title: String { "\(providerName) portfolio" }

    /// `"USD 113,674.26"`: cash plus positions at the latest marks.
    public var totalText: String { money(portfolio.total) }

    /// `"≈ AED 417,468.72"` for an account outside AED; nil in AED or without a rate.
    public var totalAedText: String? {
        guard currency != "AED", let aed = portfolio.totalAed else { return nil }
        return "≈ \(MoneyFormat.aed(aed))"
    }

    /// `"Prices as of 27 Oct"`; nil before the first marks.
    public var asOfText: String? { portfolio.asOf.map { "Prices as of \(LedgerDates.dayLabel($0, today: today))" } }

    /// Net deposits, profit, income, fees, cash and what is in positions.
    public var stats: [NoteStat] {
        let count = portfolio.positions.count
        return [
            NoteStat("Net deposits", money(portfolio.netDeposits), sub: "Money in less money out"),
            NoteStat("Profit", NoteText.signed(portfolio.profit, currency: currency), sub: "Value now against net deposits",
                     tone: NoteText.profitTone(portfolio.profit)),
            NoteStat("Income", money(portfolio.income), sub: "Coupons, dividends and interest"),
            NoteStat("Fees", money(portfolio.fees), sub: "Charged by the broker"),
            NoteStat("Cash", portfolio.cash.map(money) ?? "—", sub: portfolio.cash == nil ? "No cash figure yet" : nil),
            NoteStat("In positions", money(portfolio.positionsValue),
                     sub: count == 1 ? "1 position" : "\(count) positions"),
        ]
    }

    // MARK: Sync

    public struct SyncLine: Sendable, Hashable {
        public let text: String
        public let tone: Tone
        public let detail: String?
    }

    /// How fresh the figures are. A failed attempt says so (with the broker's error and the last
    /// good sync); a sync two or more days old is late (it runs daily); never synced says what the
    /// first sync brings.
    public var sync: SyncLine {
        let s = portfolio.sync
        let lastGood = s.lastSyncedAt.map { CashText.relative($0, now: now) }
        if s.status == "error" {
            let detail = [s.error.flatMap { $0.isEmpty ? nil : $0 }, lastGood.map { "Last good sync \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            return SyncLine(text: "Last sync failed", tone: .danger, detail: detail.isEmpty ? nil : detail)
        }
        guard let synced = s.lastSyncedAt, let lastGood else {
            return SyncLine(text: "Not synced yet", tone: .neutral,
                            detail: "The first sync brings in the positions and their history.")
        }
        let late = CalendarDay(date: synced).days(until: today) >= 2
        return SyncLine(text: "Synced with \(providerName) \(lastGood)", tone: late ? .warn : .neutral,
                        detail: late ? "It syncs every day; this one is late." : nil)
    }

    // MARK: Lists

    /// The positions, largest value first (unpriced last, then by name).
    public var positions: [BrokerPositionRow] {
        portfolio.positions
            .sorted { a, b in
                switch (a.value, b.value) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            .map { BrokerPositionRow($0, today: today) }
    }

    /// The positions that ended, latest first.
    public var closed: [BrokerClosedRow] {
        portfolio.closed
            .sorted { ($0.closedOn ?? .init(year: 1, month: 1, day: 1)) > ($1.closedOn ?? .init(year: 1, month: 1, day: 1)) }
            .map { BrokerClosedRow($0, currency: currency) }
    }

    /// Instead of the positions list.
    public var positionsEmptyMessage: String {
        portfolio.asOf == nil ? "Positions show after the first sync." : "No positions: everything is in cash."
    }

    // MARK: Chart

    public var chart: BrokerValueChart { BrokerValueChart(portfolio.series, currency: currency) }
}

/// One position, worded.
public struct BrokerPositionRow: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let title: String
    /// `"25,000 nominal at 93.42%"`, `"32 × USD 253.64"`.
    public let holdingText: String?
    /// `"AMZN · US0231351067"`.
    public let caption: String?
    public let valueText: String
    /// Sold today with what it paid, against what went in: `"−USD 1,737.50 (−6.92%)"`.
    public let profitText: String?
    public let profitTone: Tone
    /// `"USD 2,114.58 paid so far"`.
    public let incomeText: String?
    public let chips: [Chip]
    /// A note: sold today next to if called at its next autocall date.
    public let exits: [NoteExit]
    /// A structured note with terms opens the note screen.
    public let opensNote: Bool

    public struct Chip: Sendable, Hashable {
        public let label: String
        public let tone: Tone
    }

    init(_ p: BrokerPortfolio.Position, today: CalendarDay) {
        holdingCode = p.holdingCode
        title = p.name
        holdingText = Self.holding(p)
        let caption = [p.symbol, p.isin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        self.caption = caption.isEmpty ? nil : caption
        valueText = p.value.map { MoneyFormat.amount($0, currency: p.currency) } ?? "No price"
        if let s = p.sellNow {
            profitText = "\(NoteText.signed(s.profit, currency: p.currency)) (\(NoteText.signedPct(s.returnPct)))"
            profitTone = NoteText.profitTone(s.profit)
        } else {
            profitText = p.profit.map { NoteText.signed($0, currency: p.currency) }
            profitTone = NoteText.profitTone(p.profit)
        }
        incomeText = p.income > 0 ? "\(MoneyFormat.amount(p.income, currency: p.currency)) paid so far" : nil
        var chips: [Chip] = []
        var exits: [NoteExit] = []
        if let note = p.note {
            if note.noteStatus != .live { chips.append(Chip(label: note.noteStatus.label, tone: note.noteStatus.tone)) }
            if note.awaitingPrices == true { chips.append(Chip(label: "Awaiting prices", tone: .warn)) }
            if let s = p.sellNow {
                exits.append(.sellToday(total: s.total, profit: s.profit, returnPct: s.returnPct,
                                        bidPct: p.priceInPct ? p.price : nil, currency: p.currency))
            }
            if !note.noteStatus.isEnded, let called = note.ifCalledNext {
                exits.append(.ifCalled(called, currency: p.currency, today: today))
            }
        }
        self.chips = chips
        self.exits = exits
        opensNote = p.note != nil
    }

    /// The quantity and price: a nominal at a % price, or units at a unit price.
    static func holding(_ p: BrokerPortfolio.Position) -> String? {
        guard let q = p.quantity else { return nil }
        let qty = BrokerText.quantity(q)
        guard let price = p.price else { return p.priceInPct ? "\(qty) nominal" : "\(qty) units" }
        return p.priceInPct
            ? "\(qty) nominal at \(NoteText.pct(price, digits: 2))"
            : "\(qty) × \(MoneyFormat.amount(price, currency: p.currency))"
    }

    /// For VoiceOver.
    public var accessibilityLabel: String {
        ([title, holdingText, valueText, profitText, incomeText].compactMap { $0 }
            + chips.map(\.label) + exits.map(\.accessibilityLabel)).joined(separator: ", ")
    }
}

/// One position that ended, worded.
public struct BrokerClosedRow: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let title: String
    /// `"Called early"` for a note, `"Sold"` otherwise.
    public let status: String
    public let statusTone: Tone
    /// `"3 Feb 2026 – 9 Sep 2026"`.
    public let dates: String?
    /// `"USD 20,050.00 in · USD 22,926.00 back · USD 4,230.00 income"`.
    public let flows: String
    public let profitText: String
    public let profitTone: Tone
    /// `"+14.34% · 25.16% a year"`.
    public let returnText: String?
    /// A structured note opens the note screen.
    public let opensNote: Bool

    /// For VoiceOver.
    public var accessibilityLabel: String {
        ([title, status, dates, flows, profitText, returnText].compactMap { $0 }).joined(separator: ", ")
    }

    /// `currency` is the account's (an ended position carries none of its own).
    init(_ c: BrokerPortfolio.ClosedPosition, currency: String) {
        func money(_ v: Decimal) -> String { MoneyFormat.amount(v, currency: currency) }
        holdingCode = c.holdingCode
        title = c.name
        if let raw = c.noteStatus {
            let s = NoteStatus(raw: raw)
            status = s.label
            statusTone = s.tone
        } else {
            status = "Sold"
            statusTone = .neutral
        }
        switch (c.openedOn, c.closedOn) {
        case let (o?, e?): dates = "\(LedgerDates.fullDayLabel(o)) – \(LedgerDates.fullDayLabel(e))"
        case let (nil, e?): dates = "Ended \(LedgerDates.fullDayLabel(e))"
        default: dates = nil
        }
        flows = (["\(money(c.invested)) in", "\(money(c.returned)) back"]
            + (c.income > 0 ? ["\(money(c.income)) income"] : [])).joined(separator: " · ")
        profitText = NoteText.signed(c.profit, currency: currency)
        profitTone = NoteText.profitTone(c.profit)
        let ret = [c.returnPct.map(NoteText.signedPct), c.annualisedPct.map { "\(NoteText.pct($0)) a year" }]
            .compactMap { $0 }.joined(separator: " · ")
        returnText = ret.isEmpty ? nil : ret
        opensNote = c.noteStatus != nil
    }
}

/// Words shared by the broker rows.
public enum BrokerText {
    /// `25000` → `"25,000"`; `1.5` → `"1.5"` (units can be fractional).
    public static func quantity(_ q: Decimal) -> String {
        if MoneyFormat.rounded(q, scale: 0) == q { return MoneyFormat.grouped(q, fractionDigits: 0) }
        var text = MoneyFormat.grouped(q, fractionDigits: 6)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}

/// What the account screen shows of the broker portfolio. Every account asks
/// (`broker_portfolio` answers null without a sync), so only a broker account (Swissquote, where
/// the sync runs) shows its loading and failure; any other account shows nothing until a
/// portfolio arrives.
public enum BrokerSection: Sendable, Hashable {
    case hidden
    case loading
    case failed(String)
    case loaded(BrokerPortfolioPresentation)

    /// The banks whose accounts sync from a broker.
    public static let brokerBanks: Set<String> = ["SWQ"]

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

import Foundation

/// India mode's Overview, worded: rupees first (the accounts' own currency), AED second. Every
/// figure is `india_overview`'s; nothing here adds money up (CLAUDE.md §2.2).
public struct IndiaHero: Sendable, Hashable {
    public let currency: String
    /// Whole rupees, grouped like every other figure (`"1,234,567"`); the unit (`"INR"`) is
    /// drawn beside it.
    public let amount: String
    /// `"≈ AED 54,321"`; nil without an AED value.
    public let aedText: String?
    /// Invested, P&L, cash and the last 24 hours, as far as they are known.
    public let lines: [ReturnFigures.Line]
    /// `"Synced today, 14:00"`; nil before the first sync.
    public let syncText: String?
    public let accessibilityLabel: String

    public init(_ o: IndiaOverview, now: Date = .now) {
        let t = o.total
        let cur = o.currency
        currency = cur
        amount = MoneyFormat.hero(t.value ?? 0)
        aedText = t.valueAed.map { "≈ " + MoneyFormat.aed($0, fractionDigits: 0) }
        var lines: [ReturnFigures.Line] = []
        if let invested = t.invested {
            lines.append(.init(label: "Invested", text: NoteText.whole(invested, currency: cur), tone: .neutral))
        }
        if let pnl = t.pnl {
            lines.append(.init(label: "P&L", text: IndiaText.signedWithPct(pnl, t.pnlPct, currency: cur),
                               tone: HoldingsText.tone(pnl)))
        }
        if let cash = t.cash, cash != 0 {
            lines.append(.init(label: "Cash", text: NoteText.whole(cash, currency: cur), tone: .neutral))
        }
        if let change = IndiaText.change(t.change24h, t.change24hPct, currency: cur) {
            lines.append(.init(label: "Last 24 hours", text: change, tone: HoldingsText.tone(t.change24h)))
        }
        self.lines = lines
        syncText = t.lastSyncedAt.map { "Synced " + CashText.relative($0, now: now) }
        accessibilityLabel = (["India, all accounts", NoteText.whole(t.value ?? 0, currency: cur), aedText]
            .compactMap { $0 }).joined(separator: ", ")
    }
}

/// One India account on the Overview: `"Zerodha Kite"`, `"INR 812,450"` with `"≈ AED 35,600"`
/// under it, `"+INR 64,210 (+8.59%) · 8 positions"` and the 24-hour move. Opens its tab.
public struct IndiaAccountRow: Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    public let bankCode: String?
    public let title: String
    public let valueText: String
    public let aedText: String?
    public let detail: String
    public let detailTone: Tone
    /// `"+INR 1,204 (+0.29%) in 24h"`; nil without a move.
    public let changeText: String?
    public let changeTone: Tone
    public let syncFailed: Bool
    /// The tab it opens; nil for an account this build has no tab for.
    public let tab: LedgerTab?

    public init(_ a: IndiaOverview.Account, currency: String) {
        accountCode = a.accountCode
        bankCode = a.bankCode
        title = a.name
        valueText = NoteText.whole(a.value ?? 0, currency: currency)
        aedText = a.valueAed.map { "≈ " + MoneyFormat.aed($0, fractionDigits: 0) }
        syncFailed = a.syncStatus == "error"
        let positions = a.positions == 1 ? "1 position" : "\(a.positions) positions"
        detail = [a.pnl.map { IndiaText.signedWithPct($0, a.pnlPct, currency: currency) },
                  a.positions > 0 ? positions : nil,
                  syncFailed ? "last sync failed" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        detailTone = syncFailed ? .warn : HoldingsText.tone(a.pnl)
        changeText = IndiaText.change(a.change24h, a.change24hPct, currency: currency).map { $0 + " in 24h" }
        changeTone = HoldingsText.tone(a.change24h)
        tab = a.tab
    }

    public var accessibilityLabel: String {
        [title, valueText, aedText, detail, changeText].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The period block under the chart: start, money added, now, growth and return, in rupees.
public enum IndiaPeriod {
    /// Only the figures the server sent.
    public static func lines(_ o: IndiaOverview) -> [ReturnFigures.Line] {
        let t = o.total
        let cur = o.currency
        var out: [ReturnFigures.Line] = []
        if let v = t.periodStartValue { out.append(.init(label: "Value at start", text: NoteText.whole(v, currency: cur), tone: .neutral)) }
        if let v = t.periodAdded { out.append(.init(label: "Money added", text: NoteText.signedWhole(v, currency: cur), tone: .neutral)) }
        if let v = t.periodEndValue { out.append(.init(label: "Value now", text: NoteText.whole(v, currency: cur), tone: .neutral)) }
        if let v = t.periodGrowth {
            out.append(.init(label: "Growth", text: NoteText.signedWhole(v, currency: cur), tone: HoldingsText.tone(v)))
        }
        if let v = t.periodGrowthPct {
            out.append(.init(label: "Return", text: HoldingsText.signedPercent(v), tone: HoldingsText.tone(v)))
        }
        return out
    }

    /// `"Since 30 Jul 2026"`; nil without a start day.
    public static func rangeText(_ o: IndiaOverview) -> String? {
        o.from.map { "Since " + LedgerDates.fullDayLabel($0) }
    }

    /// Instead of the lines, when the server sent none.
    public static let emptyMessage = "No figures for this period yet: they show after the accounts' first syncs."

    /// What growth is.
    public static let note = "Growth leaves out money added: what the accounts made, not what went in."
}

/// India's value chart: every India account's value against what its open positions cost.
public enum IndiaChart {
    /// The days with a value, oldest first.
    public static func known(_ points: [IndiaOverview.Point]) -> [IndiaOverview.Point] {
        points.filter { $0.value != nil }.sorted { $0.date < $1.date }
    }

    public static let note = "Each day's value of the Kite and Coin accounts against what their open positions cost."
    public static let tooFewMessage = "Not enough history yet: a line shows from the second day of syncs."
}

/// What India mode says when the ledger has no India account (a removed account, or a stale
/// remembered mode before the fallback to Spending).
public enum IndiaText {
    public static let unavailableMessage = "This ledger has no Zerodha Kite or Coin account."

    /// `"+INR 64,210 (+8.59%)"`, `"−INR 1,200"`.
    public static func signedWithPct(_ value: Decimal, _ pct: Decimal?, currency: String) -> String {
        NoteText.signedWhole(value, currency: currency) + (pct.map { " (\(HoldingsText.signedPercent($0)))" } ?? "")
    }

    /// The 24-hour move; nil when unknown or under one rupee.
    public static func change(_ value: Decimal?, _ pct: Decimal?, currency: String) -> String? {
        guard let value, MoneyFormat.rounded(value, scale: 0) != 0 else { return nil }
        return signedWithPct(value, pct, currency: currency)
    }

    /// The India Overview's rows, one per account, Kite first as the server sends them.
    public static func rows(_ o: IndiaOverview) -> [IndiaAccountRow] {
        o.accounts.map { IndiaAccountRow($0, currency: o.currency) }
    }
}

import Foundation

/// A live note on the broker account's Portfolio: its name, its verdict, what it is worth today
/// next to what it pays if called at its next date (or what was paid, with no call date left), and
/// its stocks on bars. Opens the note screen. Every figure is the server's.
public struct BrokerNoteCard: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let title: String
    /// `"Called on 15 Mar 2027 if GOOGL rises 9.3%"`; nil without a verdict this build can word.
    public let verdict: String?
    public let verdictTone: Tone
    /// "Worth today", then "If called on …" (or "Paid").
    public let figures: [NoteStat]
    public let bars: [NoteStockBar]

    init(_ p: BrokerPortfolio.Position, today: CalendarDay) {
        holdingCode = p.holdingCode
        title = p.name
        verdict = p.note?.verdict?.headline(today: today)
        verdictTone = p.note?.verdict?.tone ?? .neutral
        let worth = NoteStat("Worth today", p.value.map { NoteText.whole($0, currency: p.currency) } ?? "No price")
        if let called = p.note?.ifCalledNext {
            figures = [worth, NoteStat("If called on \(LedgerDates.dayLabel(called.obsDate, today: today))",
                                       NoteText.whole(called.total, currency: p.currency),
                                       sub: NoteText.profitLine(called.profit, annualisedPct: called.annualisedPct,
                                                                currency: p.currency),
                                       tone: NoteText.profitTone(called.profit))]
        } else {
            figures = [worth, NoteStat("Paid", NoteText.whole(p.invested, currency: p.currency))]
        }
        bars = NoteStockBar.bars(p.note?.underlyings ?? [])
    }

    /// For VoiceOver.
    public var accessibilityLabel: String {
        ([title, verdict].compactMap { $0 }
            + figures.map { "\($0.label) \($0.value)" + ($0.sub.map { ", \($0)" } ?? "") }
            + bars.map(\.accessibilityLabel)).joined(separator: "; ")
    }
}

/// Anything else the account holds (shares, a note the ledger has no terms for), in one line:
/// name, value and profit. Opens the holding's screen.
public struct BrokerHoldingRow: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let title: String
    /// `"USD 8,142"`, or `"No price"`.
    public let valueText: String
    /// `"+USD 1,594 (+24.4%)"`: sold today with what it has paid, against what went in.
    public let profitText: String?
    public let profitTone: Tone
    /// A structured note with terms opens the note screen; anything else its holding screen.
    public let opensNote: Bool

    init(_ p: BrokerPortfolio.Position) {
        holdingCode = p.holdingCode
        title = p.name
        opensNote = p.note != nil
        valueText = p.value.map { NoteText.whole($0, currency: p.currency) } ?? "No price"
        if let s = p.sellNow {
            profitText = "\(NoteText.signedWhole(s.profit, currency: p.currency)) (\(NoteText.signedPct(s.returnPct, digits: 1)))"
            profitTone = NoteText.profitTone(s.profit)
        } else {
            profitText = p.profit.map { NoteText.signedWhole($0, currency: p.currency) }
            profitTone = NoteText.profitTone(p.profit)
        }
    }

    /// For VoiceOver.
    public var accessibilityLabel: String { [title, valueText, profitText].compactMap { $0 }.joined(separator: ", ") }
}

/// A position that ended, in one line: name, how long it was held, profit and the return.
public struct BrokerPastRow: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let title: String
    /// `"held Feb–Sep 2026"`.
    public let heldText: String?
    /// `"+USD 2,876"`.
    public let profitText: String
    public let profitTone: Tone
    /// `"+14.3% · 25% a year"`.
    public let returnText: String?
    /// A structured note opens the note screen; anything else its holding screen.
    public let opensNote: Bool

    /// `currency` is the account's (an ended position carries none of its own).
    init(_ c: BrokerPortfolio.ClosedPosition, currency: String) {
        holdingCode = c.holdingCode
        title = c.name
        heldText = Self.held(c.openedOn, c.closedOn)
        profitText = NoteText.signedWhole(c.profit, currency: currency)
        profitTone = NoteText.profitTone(c.profit)
        let ret = [c.returnPct.map { NoteText.signedPct($0, digits: 1) },
                   c.annualisedPct.map { "\(NoteText.pct($0, digits: 0)) a year" }]
            .compactMap { $0 }.joined(separator: " · ")
        returnText = ret.isEmpty ? nil : ret
        opensNote = c.noteStatus != nil
    }

    /// `"held Feb–Sep 2026"`, `"held Dec 2025–Aug 2026"`, `"held Mar 2026"`, `"ended Sep 2026"`.
    static func held(_ opened: CalendarDay?, _ closed: CalendarDay?) -> String? {
        guard let closed else { return nil }
        guard let opened else { return "ended \(LedgerDates.shortMonthYear(closed))" }
        if opened.year == closed.year {
            if opened.month == closed.month { return "held \(LedgerDates.shortMonthYear(closed))" }
            return "held \(LedgerDates.monthAbbrev(opened))–\(LedgerDates.shortMonthYear(closed))"
        }
        return "held \(LedgerDates.shortMonthYear(opened))–\(LedgerDates.shortMonthYear(closed))"
    }

    /// For VoiceOver.
    public var accessibilityLabel: String {
        [title, heldText, profitText, returnText].compactMap { $0 }.joined(separator: ", ")
    }
}

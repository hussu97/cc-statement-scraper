import Foundation

/// One way out of a live note, side by side with the other: sold today at the broker's bid, or
/// held until it is called at its next autocall date. Every figure is the server's
/// (`broker_portfolio.positions[].sell_now` / `note.if_called_next`, `structured_notes_summary`'s
/// `market` / `if_called_next`); this only words it.
public struct NoteExit: Sendable, Hashable, Identifiable {
    public var id: String { title }
    /// `"Sell today"`, `"If called 15 Mar"`.
    public let title: String
    /// What it pays back in all: `"USD 23,355.00"`.
    public let totalText: String
    /// `"−USD 1,737.50"`, `"+USD 3,845.00"`.
    public let profitText: String
    public let tone: Tone
    /// `"−6.92% · bid 93.42%"`, `"+15.32% · 28.12% a year"`.
    public let detail: String?

    /// Sold today: `total` is the bid value plus what the note has paid so far.
    public static func sellToday(total: Decimal, profit: Decimal, returnPct: Decimal?, bidPct: Decimal?,
                                 currency: String) -> NoteExit {
        let detail = [returnPct.map(NoteText.signedPct), bidPct.map { "bid \(NoteText.pct($0, digits: 2))" }]
            .compactMap { $0 }.joined(separator: " · ")
        return NoteExit(title: "Sell today", totalText: MoneyFormat.amount(total, currency: currency),
                        profitText: NoteText.signed(profit, currency: currency), tone: NoteText.profitTone(profit),
                        detail: detail.isEmpty ? nil : detail)
    }

    /// Called at its next autocall date (coupons up to it paid).
    public static func ifCalled(_ s: NoteDetail.AutocallScenario, currency: String,
                                today: CalendarDay = LedgerDates.today()) -> NoteExit {
        let detail = [NoteText.signedPct(s.returnPct), s.annualisedPct.map { "\(NoteText.pct($0)) a year" }]
            .compactMap { $0 }.joined(separator: " · ")
        return NoteExit(title: "If called \(LedgerDates.dayLabel(s.obsDate, today: today))",
                        totalText: MoneyFormat.amount(s.total, currency: currency),
                        profitText: NoteText.signed(s.profit, currency: currency), tone: NoteText.profitTone(s.profit),
                        detail: detail)
    }

    /// The note screen's tile: the profit, coloured, with what comes back under it.
    public var stat: NoteStat {
        NoteStat(title, profitText, sub: (["\(totalText) back"] + [detail].compactMap { $0 }).joined(separator: " · "), tone: tone)
    }

    /// `"Sell today: USD 23,355.00, −USD 1,737.50, −6.92% · bid 93.42%"` for VoiceOver.
    public var accessibilityLabel: String {
        ([ "\(title): \(totalText)", profitText] + [detail].compactMap { $0 }).joined(separator: ", ")
    }
}

extension NoteText {
    /// A return with its sign: `"+15.32%"`, `"−6.92%"`, `"0%"`.
    public static func signedPct(_ value: Decimal) -> String {
        value > 0 ? "+" + pct(value) : pct(value)
    }
}

extension NoteSummary {
    /// A live note with a broker mark: sold today against called at its next autocall date (when
    /// one is left). Empty for an ended note or one without a mark.
    public func exits(today: CalendarDay = LedgerDates.today()) -> [NoteExit] {
        guard !isEnded, let market else { return [] }
        var out = [NoteExit.sellToday(total: market.value, profit: market.profit, returnPct: nil,
                                      bidPct: market.pricePct, currency: currency)]
        if let called = ifCalledNext { out.append(.ifCalled(called, currency: currency, today: today)) }
        return out
    }
}

extension NoteDetail {
    /// The note screen's tiles for `exits`: sold today next to if called.
    public func exitStats(today: CalendarDay = LedgerDates.today()) -> [NoteStat] {
        summary.exits(today: today).map(\.stat)
    }
}

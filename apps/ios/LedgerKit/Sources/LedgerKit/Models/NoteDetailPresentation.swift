import Foundation

/// A figure with its label and the line under it (the note screen's stat tiles).
public struct NoteStat: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public let label: String
    public let value: String
    public let sub: String?
    public let tone: Tone

    public init(_ label: String, _ value: String, sub: String? = nil, tone: Tone = .neutral) {
        self.label = label
        self.value = value
        self.sub = sub
        self.tone = tone
    }
}

/// The note screen's detail, collapsed until opened.
public enum NoteSection: String, Sendable, Hashable, CaseIterable, Identifiable {
    case scenarios = "All scenarios"
    case schedule = "Full schedule"
    case priceHistory = "Price history"
    case terms = "Terms"

    public var id: String { rawValue }
    public var title: String { rawValue }
}

/// One schedule row: the dates, the coupon and autocall terms, and what happened.
public struct NoteScheduleRow: Sendable, Hashable, Identifiable {
    public var id: CalendarDay { obsDate }
    public let obsDate: CalendarDay
    public let payDate: CalendarDay
    public let coupon: String?
    public let autocall: String?
    /// Each outcome observed that day, worded; empty before it.
    public let outcomes: [Line]
    /// `"to come"` or `"awaiting prices"` while there are none.
    public let pending: String?

    public struct Line: Sendable, Hashable {
        public let text: String
        public let tone: Tone
    }
}

extension NoteDetail {
    private func money(_ v: Decimal) -> String { summary.money(v) }
    private func signed(_ v: Decimal) -> String { summary.signed(v) }

    private func whole(_ v: Decimal) -> String { NoteText.whole(v, currency: currency) }

    /// The verdict, big: `"Called on 15 Mar 2027 if GOOGL rises 9.3%"`; nil once ended (the status
    /// badge says so and the money says how it went) or without one this build words.
    public func verdictHeadline(today: CalendarDay = LedgerDates.today()) -> String? {
        isEnded ? nil : summary.verdict?.headline(today: today)
    }

    public var verdictTone: Tone { summary.verdict?.tone ?? .neutral }

    /// Under the verdict: when the next check is and what it takes; for a coupon at risk, what the
    /// coupon pays and when the call comes. Empty once ended.
    /// `"Next check 15 Mar 2027 · in 139 days · called if every stock is at or above 100% of its start"`.
    public func countdown(today: CalendarDay = LedgerDates.today()) -> [String] {
        guard !isEnded, let next = summary.next else { return [] }
        let when = "\(LedgerDates.fullDayLabel(next.obsDate)) · \(NoteText.inDays(next.days))"
        let atRisk = summary.verdict?.kind == .couponAtRisk
        var lines: [String] = []
        if next.isFinal {
            lines.append("Final valuation \(when)")
        } else if let call = next.autocall {
            lines.append("Next check \(when) · called if every stock is at or above \(NoteText.pct(call.triggerPct)) of its start")
        } else if let coupon = next.coupon, !atRisk {
            lines.append("Next check \(when) · coupon paid if every stock is at or above \(NoteText.pct(coupon.barrierPct)) of its start")
        } else {
            lines.append("Next check \(when)")
        }
        if atRisk, let coupon = next.coupon {
            lines.append("Coupon of \(money(coupon.amount)) is paid only if every stock is at or above "
                         + "\(NoteText.pct(coupon.barrierPct)) of its start")
        }
        if let call = summary.verdict?.callLine(today: today) { lines.append(call) }
        return lines
    }

    /// The stocks on bars, the one holding it back first; none once ended.
    public var bars: [NoteStockBar] { isEnded ? [] : NoteStockBar.bars(underlyings) }

    /// The money in three numbers. Live: paid, worth today (and what selling would make), if called
    /// at the next date. Ended: paid, got back, profit.
    public func moneyStats(today: CalendarDay = LedgerDates.today()) -> [NoteStat] {
        let s = summary
        let paid = NoteStat("Paid", whole(s.invested))
        if isEnded {
            guard let r = s.result else { return [paid] }
            return [paid, NoteStat("Got back", whole(r.total)),
                    NoteStat("Profit", NoteText.signedWhole(r.profit, currency: currency),
                             sub: NoteText.signedPct(r.returnPct, digits: 1), tone: NoteText.profitTone(r.profit))]
        }
        var out = [paid, NoteStat("Worth today", s.market.map { whole($0.value) } ?? "—",
                                  sub: s.market.map { "\(NoteText.signedWhole($0.profit, currency: currency)) if sold today" }
                                      ?? "No broker price yet",
                                  tone: .neutral)]
        if let c = s.ifCalledNext {
            out.append(NoteStat("If called on \(LedgerDates.dayLabel(c.obsDate, today: today))", whole(c.total),
                                sub: NoteText.profitLine(c.profit, annualisedPct: c.annualisedPct, currency: currency),
                                tone: NoteText.profitTone(c.profit)))
        }
        return out
    }

    /// The collapsed sections this note has: scenarios only while the server has them, the price
    /// history once there are closes.
    public var sections: [NoteSection] {
        NoteSection.allCases.filter { section in
            switch section {
            case .scenarios: scenarios != nil
            case .priceHistory: !seriesLines.isEmpty
            case .schedule, .terms: true
            }
        }
    }

    /// The schedule in one line, for its collapsed section.
    public var scheduleSummary: String {
        NoteText.scheduleSummary(observations.map {
            NoteText.ScheduleEntry(obsDate: $0.obsDate, couponRatePct: $0.couponRatePct, couponBarrierPct: $0.couponBarrierPct,
                                   couponMemory: $0.couponMemory, autocallTriggerPct: $0.autocallTriggerPct)
        })
    }

    /// The scenarios' four tiles.
    public var scenarioStats: [NoteStat] {
        guard let s = scenarios else { return [] }
        let bestSub = s.best.date.map { "\(s.best.when == "autocall" ? "Called" : "Matures") \(LedgerDates.fullDayLabel($0)), every coupon paid" }
        return [
            NoteStat("Best case", signed(s.best.profit), sub: bestSub, tone: .positive),
            NoteStat("Worst case", signed(s.worst.profit), sub: "The stock holding it back falls to zero; coupons received kept", tone: .danger),
            NoteStat("Coupons still to come", money(s.remainingCoupons), sub: "If every remaining one is paid"),
            NoteStat("Break-even at maturity", NoteText.pct(summary.breakEvenPct),
                     sub: "Where the lowest stock must end to return what you paid"),
        ]
    }

    /// The payoff curve's rows worth showing, highest worst level first.
    public var maturityRows: [MaturityPoint] {
        guard let s = scenarios else { return [] }
        return NoteText.maturityTableRows(s.maturity, branches: payout).reversed()
    }

    /// Each observation with its terms and what happened that day.
    public var scheduleRows: [NoteScheduleRow] {
        observations.map { o in
            let outs = outcomes(on: o.obsDate).map { x -> NoteScheduleRow.Line in
                let amount = x.amount.map { " \(money($0))" } ?? ""
                return NoteScheduleRow.Line(
                    text: "\(NoteText.outcomeLabel(x.kind))\(amount) · worst \(x.worstSymbol) \(NoteText.pct(x.worstPct, digits: 2))",
                    tone: NoteText.outcomeTone(x.kind))
            }
            let awaiting = summary.awaitingPrices && o.obsDate <= (summary.next?.obsDate ?? o.obsDate)
            return NoteScheduleRow(
                obsDate: o.obsDate, payDate: o.payDate,
                coupon: o.couponRatePct.map { "\(NoteText.pct($0)) if ≥ \(NoteText.pct(o.couponBarrierPct))\(o.couponMemory ? " (memory)" : "")" },
                autocall: o.autocallTriggerPct.map { "\(NoteText.pct(o.autocallAmountPct)) if ≥ \(NoteText.pct($0))" },
                outcomes: outs,
                pending: outs.isEmpty ? (awaiting ? "awaiting prices" : "to come") : nil)
        }
    }

    /// The schedule card's title line: `"19 observation dates"`.
    public var scheduleCaption: String {
        observations.count == 1 ? "1 observation date" : "\(observations.count) observation dates"
    }

    /// The terms as read from the term sheet.
    public var termRows: [(label: String, value: String)] {
        let issuer = [summary.issuer, terms.guarantor.map { "guaranteed by \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return [
            ("Product", summary.productName),
            ("Issuer", issuer.isEmpty ? "—" : issuer),
            ("ISIN", summary.isin ?? "—"),
            ("Denomination", "\(money(terms.denomination)) at \(NoteText.pct(terms.issuePricePct)) issue price"),
            ("Strike", LedgerDates.fullDayLabel(terms.strikeDate)),
            ("Final valuation", LedgerDates.fullDayLabel(terms.finalValuationDate)),
            ("Maturity", LedgerDates.fullDayLabel(terms.maturityDate)),
            ("Term sheet", terms.termsheetFilename ?? "—"),
        ]
    }

    /// The header's one muted line: `"Example Bank M Financial · XS0000000405"`.
    public var headerDetail: String {
        [summary.issuer, summary.isin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

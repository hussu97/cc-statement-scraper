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

/// What the next observation would do at today's prices.
public struct NoteOutlook: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public let title: String
    public let text: String
    public let ok: Bool
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

    /// Invested, received, then the result (ended) or what it would pay ended today and break-even.
    public var summaryStats: [NoteStat] {
        let s = summary
        var out = [
            NoteStat("Invested", money(s.invested),
                     sub: "\(money(s.nominal)) nominal at \(NoteText.pct(s.purchasePricePct)) · \(LedgerDates.fullDayLabel(s.tradeDate))"),
            NoteStat("Received", money(s.received.total),
                     sub: "Coupons \(money(s.received.coupons))" + (s.due.total > 0 ? " · \(money(s.due.total)) due" : "")),
        ]
        if let r = s.result {
            out.append(NoteStat("Result", signed(r.profit), sub: "\(NoteText.pct(r.returnPct)) on what you put in",
                                tone: NoteText.profitTone(r.profit)))
            out.append(NoteStat("Ended", s.endedOn.map(LedgerDates.fullDayLabel) ?? "—", sub: s.noteStatus.label))
        } else {
            let t = s.ifEndedToday
            out.append(NoteStat("If it ended today", t.map { signed($0.profit) } ?? "—",
                                sub: t.map { "\(NoteText.pct($0.payoutPct)) of nominal\($0.settlement == "physical" ? " in shares" : ""), with coupons received" }
                                    ?? "Needs today's prices",
                                tone: NoteText.profitTone(t?.profit)))
            out.append(NoteStat("Break-even at maturity", s.breakEvenPct.map { "worst ≥ \(NoteText.pct($0))" } ?? "—",
                                sub: "Matures \(LedgerDates.fullDayLabel(s.maturityDate)); coupons aside"))
        }
        return out
    }

    /// `"26 Nov 2026 · in 30 days"`, or `"None left"`.
    public var nextTitle: String {
        guard let next = summary.next else { return "None left" }
        return "\(LedgerDates.fullDayLabel(next.obsDate)) · \(NoteText.inDays(next.days))"
    }

    /// The next date's coupon, autocall and (at the final valuation) repayment at today's prices.
    public var outlooks: [NoteOutlook] {
        guard let next = summary.next else { return [] }
        var out: [NoteOutlook] = []
        if let c = next.coupon {
            let memory = (memoryUnpaidPct ?? 0) > 0 ? " (with missed ones)" : ""
            out.append(NoteOutlook(
                title: "Coupon \(NoteText.pct(c.ratePct))\(memory)",
                text: c.wouldPay ? "Would pay \(money(c.amount)) on \(LedgerDates.fullDayLabel(next.payDate))"
                                 : "Not at today's prices: the worst share must be at \(NoteText.pct(c.barrierPct)) or above",
                ok: c.wouldPay))
        }
        if let a = next.autocall {
            out.append(NoteOutlook(
                title: "Autocall at \(NoteText.pct(a.triggerPct))",
                text: a.wouldCall ? "Would repay \(money(a.amount)) (\(NoteText.pct(a.redemptionPct))) and end the note"
                                  : "Not at today's prices: every share must be at \(NoteText.pct(a.triggerPct)) of its initial level",
                ok: a.wouldCall))
        }
        if next.isFinal, let t = summary.ifEndedToday {
            out.append(NoteOutlook(title: "Final valuation", text: "At today's prices it repays \(money(t.amount))",
                                   ok: t.profit >= 0))
        }
        return out
    }

    /// `"AMZN at 87.05% of its initial level"`.
    public var worstNowText: String? {
        summary.worstNow.map { "\($0.symbol) at \(NoteText.pct($0.pct, digits: 2)) of its initial level" }
    }

    /// Above the levels list: `"The worst share (AMZN, 87.05%) against each level:"`; nil when it isn't shown.
    public var levelsIntro: String? {
        guard !isEnded, let levels, !levels.isEmpty, let w = summary.worstNow else { return nil }
        return "The worst share (\(w.symbol), \(NoteText.pct(w.pct, digits: 2))) against each level:"
    }

    /// The scenarios' four tiles.
    public var scenarioStats: [NoteStat] {
        guard let s = scenarios else { return [] }
        let bestSub = s.best.date.map { "\(s.best.when == "autocall" ? "Called" : "Matures") \(LedgerDates.fullDayLabel($0)), every coupon paid" }
        return [
            NoteStat("Best case", signed(s.best.profit), sub: bestSub, tone: .positive),
            NoteStat("Worst case", signed(s.worst.profit), sub: "The worst share falls to zero; coupons received kept", tone: .danger),
            NoteStat("Coupons still to come", money(s.remainingCoupons), sub: "If every remaining one is paid"),
            NoteStat("Break-even at maturity", NoteText.pct(summary.breakEvenPct),
                     sub: "Worst share level that returns what you paid"),
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

    /// The header's line under the name: `"XS353… · Marex Financial · Swissquote"`.
    public var headerDetail: String {
        [summary.isin, summary.issuer, summary.institution].compactMap { $0 }.joined(separator: " · ")
    }
}

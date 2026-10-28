import Foundation

/// A credit-linked note's reference entity on its screen: who it is, the bond it points at, and
/// what a credit event would cost today.
public struct NoteCreditEntity: Sendable, Hashable {
    /// `"Example Airlines Group Inc"`.
    public let name: String
    /// `"Senior · reference bond US0000AA0001"`.
    public let detail: String?
    /// What a credit event would do; nil once the note has ended.
    public let risk: String?

    /// For VoiceOver.
    public var accessibilityLabel: String { [name, detail, risk].compactMap { $0 }.joined(separator: ", ") }
}

/// One coupon on a credit-linked note's schedule: when, how much and what became of it.
public struct NoteCouponRow: Sendable, Hashable, Identifiable {
    public let id: Int
    /// `"20 Nov 2026"`.
    public let date: String
    /// `"USD 87.50"`.
    public let amount: String
    /// `"Paid"`, `"To come"`, `"Before you bought"`, `"Not paid"`.
    public let status: String
    public let tone: Tone
    /// Paid at maturity: `"interest from 13 Feb 2025 at 13.25% a year"`.
    public let detail: String?
    /// The first coupon still to come.
    public let isNext: Bool
}

/// One date the issuer may repay a credit-linked note early.
public struct NoteCallDateRow: Sendable, Hashable, Identifiable {
    public var id: CalendarDay { day }
    public let day: CalendarDay
    /// `"20 Dec 2026"`.
    public let date: String
    /// `"Next"` or `"Passed"`; nil for a later one.
    public let mark: String?
    public let tone: Tone
    /// Gone by: drawn muted.
    public var isPast: Bool { mark == "Passed" }
}

extension NoteDetail {
    /// The credit figures of a credit-linked note; nil for an equity one.
    public var credit: NoteCredit? { summary.isCreditLinked ? summary.credit : nil }

    private func money(_ v: Decimal) -> String { summary.money(v) }
    private static func day(_ d: CalendarDay) -> String { LedgerDates.fullDayLabel(d) }

    /// Under the verdict: the next coupon (or the interest building up) and, while the issuer can
    /// still call it, what that would pay back.
    /// `"If called on 20 Dec 2026: USD 17,436.90 back (+USD 3,336.90)"`.
    var creditCountdown: [String] {
        var lines = [summary.verdict?.creditLine(currency: currency)].compactMap { $0 }
        if let c = credit?.ifCalledNext {
            lines.append("If called on \(Self.day(c.date)): \(money(c.total)) back (\(summary.signed(c.profit)))")
        }
        return lines
    }

    /// The third money tile: every coupon and the face value, held to maturity.
    var heldToMaturityStat: NoteStat? {
        guard let m = credit?.toMaturity else { return nil }
        return NoteStat("Held to maturity", NoteText.whole(m.total, currency: currency),
                        sub: NoteText.profitLine(m.profit, annualisedPct: m.annualisedPct, currency: currency, digits: 1),
                        tone: NoteText.profitTone(m.profit))
    }

    var creditSections: [NoteSection] {
        [.couponSchedule] + ((credit?.callDates.isEmpty ?? true) ? [] : [.callDates]) + [.terms]
    }

    /// The reference entity card, in place of the stocks.
    public var creditEntity: NoteCreditEntity? {
        guard let c = credit else { return nil }
        let name = c.referenceEntity.isEmpty ? "The reference entity" : c.referenceEntity
        let detail = [c.seniority, c.referenceObligationIsin.map { "reference bond \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return NoteCreditEntity(name: name, detail: detail.isEmpty ? nil : detail, risk: creditRisk(c, entity: name))
    }

    /// `"If Example Airlines Group Inc has a credit event (default, bankruptcy or restructuring),
    /// interest stops and the note repays what the market recovers, possibly far below 100%. At risk
    /// now: USD 10,000.00 face value and USD 5,425.00 of interest to come; the USD 14.58 already
    /// received is kept."`
    private func creditRisk(_ c: NoteCredit, entity: String) -> String? {
        guard let e = c.creditEvent else { return nil }
        var text = "If \(entity) has a credit event (default, bankruptcy or restructuring), interest stops and the note "
            + "repays what the market recovers, possibly far below 100%. At risk now: \(money(e.principalAtRisk)) face value "
            + "and \(money(e.interestLost)) of interest to come"
        if c.interestAtMaturity && e.accruedLost > 0 {
            text += ", including the \(money(e.accruedLost)) accrued so far, since nothing is paid until maturity"
        }
        text += e.kept > 0 ? "; the \(money(e.kept)) already received is kept." : "."
        return text
    }

    /// The coupon schedule in one line: `"25 of 87 paid · USD 2,114.58 received · USD 5,425.00 to
    /// come"`; paid at maturity, `"Paid in one go at maturity or on a call · USD 18,276.90 to come"`.
    /// Coupons paid before the purchase (the seller's) don't count. "Received" is the server's
    /// (`received.coupons`: on a synced account what the broker paid), never a sum made here.
    public var couponScheduleCaption: String {
        guard let c = credit else { return "" }
        let toCome = c.remainingCoupons ?? 0
        let toComeText = toCome > 0 ? "\(money(toCome)) to come" : nil
        if c.interestAtMaturity {
            let head = "Paid in one go at maturity" + (c.callDates.isEmpty ? "" : " or on a call")
            return ([head, toComeText].compactMap { $0 }).joined(separator: " · ")
        }
        let held = c.schedule.filter { $0.status != "before_purchase" }
        let paid = held.filter { $0.status == "paid" }
        let received = summary.received.coupons
        return (["\(paid.count) of \(held.count) paid", "\(money(received)) received", toComeText].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// Every coupon, worded.
    public var couponRows: [NoteCouponRow] {
        guard let c = credit else { return [] }
        let next = c.schedule.first { $0.status == "to_come" }?.seq
        return c.schedule.map { row in
            let (status, tone) = Self.couponStatus(row.status)
            let start = row.periodStart ?? c.interestStartDate
            let detail = c.interestAtMaturity
                ? ["interest", start.map { "from \(Self.day($0))" }, c.couponRatePct.map { "at \(NoteText.pct($0)) a year" }]
                    .compactMap { $0 }.joined(separator: " ")
                : nil
            return NoteCouponRow(id: row.seq, date: Self.day(row.payDate), amount: money(row.amount), status: status,
                                 tone: tone, detail: detail, isNext: row.seq == next)
        }
    }

    static func couponStatus(_ raw: String) -> (String, Tone) {
        switch raw {
        case "paid": ("Paid", .positive)
        case "to_come": ("To come", .neutral)
        case "before_purchase": ("Before you bought", .neutral)
        case "not_paid": ("Not paid", .neutral)
        default: (raw.replacingOccurrences(of: "_", with: " ").capitalized, .neutral)
        }
    }

    /// The dates the issuer may call it, the next one marked and those gone by.
    public func callDateRows(today: CalendarDay = LedgerDates.today()) -> [NoteCallDateRow] {
        guard let c = credit else { return [] }
        return c.callDates.map { d in
            if d == c.nextCallDate { return NoteCallDateRow(day: d, date: Self.day(d), mark: "Next", tone: .info) }
            if d <= today { return NoteCallDateRow(day: d, date: Self.day(d), mark: "Passed", tone: .neutral) }
            return NoteCallDateRow(day: d, date: Self.day(d), mark: nil, tone: .neutral)
        }
    }

    /// `"The issuer may repay at 100% plus accrued interest on these dates, with at least 10
    /// business days' notice."`
    public var callDatesNote: String {
        let base = "The issuer may repay at 100% plus accrued interest on these dates"
        guard let days = credit?.callNoticeDays, days > 0 else { return base + "." }
        let n = MoneyFormat.plain(days)
        return base + ", with at least \(n) business \(days == 1 ? "day's" : "days'") notice."
    }

    /// Coupon, maturity and reference entity, after the rows every note has.
    var creditTermRows: [(label: String, value: String)] {
        guard let c = credit else { return [] }
        let rate = c.couponRatePct.map { "\(NoteText.pct($0)) a year" } ?? "Fixed"
        let coupon: String
        if c.interestAtMaturity {
            coupon = "\(rate), paid at maturity" + (c.callDates.isEmpty ? "" : " or call")
        } else {
            coupon = ([rate, Self.frequency(c.couponFrequency), c.dayCount, c.interestStartDate.map { "from \(Self.day($0))" }]
                .compactMap { $0 }).joined(separator: ", ")
        }
        let maturity = (c.maturityDate ?? terms.maturityDate)
        let maturityText = Self.day(maturity)
            + (c.longstopMaturityDate.map { "; as late as \(Self.day($0)) if a credit event is being determined" } ?? "")
        let entity = ([c.referenceEntity, c.seniority, c.transactionType].compactMap { $0 }.filter { !$0.isEmpty })
            .joined(separator: " · ")
        return [("Coupon", coupon), ("Maturity", maturityText), ("Reference entity", entity.isEmpty ? "—" : entity)]
    }

    /// `"paid monthly"`, `"paid twice a year"`; nil when unknown.
    static func frequency(_ raw: String?) -> String? {
        switch raw {
        case nil: nil
        case "monthly": "paid monthly"
        case "quarterly": "paid quarterly"
        case "semiannual": "paid twice a year"
        case "annual": "paid once a year"
        case "at_maturity": "paid at maturity"
        case let other?: "paid " + other.replacingOccurrences(of: "_", with: " ")
        }
    }
}

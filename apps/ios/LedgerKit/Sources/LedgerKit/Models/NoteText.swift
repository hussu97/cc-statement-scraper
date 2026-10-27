import Foundation

/// Words for structured notes, the port of the web's `lib/notes.ts`. Every figure (coupons,
/// redemptions, distances, payouts, scenarios) is the server's (`private.note_evaluate`, CLAUDE.md
/// §2.2); these helpers only word it.
public enum NoteText {
    /// `98` → `"98%"`, `0.667` → `"0.667%"`, `-24.5` → `"−24.5%"`; with `digits`, rounded to at most
    /// that many places (`91.4655`, 2 → `"91.47%"`). `"—"` when absent.
    public static func pct(_ value: Decimal?, digits: Int? = nil) -> String {
        guard var v = value else { return "—" }
        if let digits { v = MoneyFormat.rounded(v, scale: digits) }
        return (v < 0 ? "−" : "") + MoneyFormat.plain(v < 0 ? -v : v) + "%"
    }

    /// A plain number with trailing zeros dropped: `1.66666667` stays, `100.00` → `"100"`.
    static func number(_ value: Decimal) -> String { MoneyFormat.plain(value) }

    /// `"+USD 100.00"`, `"−USD 5,975.22"` (a true minus), `"USD 0.00"`.
    public static func signed(_ value: Decimal, currency: String) -> String {
        let text = MoneyFormat.amount(value < 0 ? -value : value, currency: currency)
        if MoneyFormat.rounded(value, scale: MoneyFormat.fractionDigits(for: currency)) == 0 { return text }
        return (value < 0 ? "−" : "+") + text
    }

    /// A loss is danger, anything else positive (the web's colouring of a profit).
    public static func profitTone(_ value: Decimal?) -> Tone {
        guard let value else { return .neutral }
        return value < 0 ? .danger : .positive
    }

    /// How far a share is from a level: `"needs +7.46%"` when it must rise to reach it,
    /// `"7.46% above"` when it can fall that far and still be at it, `"at the level"` at 0.
    public static func distance(_ distancePct: Decimal?) -> String {
        guard let d = distancePct else { return "—" }
        if d == 0 { return "at the level" }
        return d > 0 ? "needs +\(number(d))%" : "\(number(-d))% above"
    }

    /// At or above a level: the condition holds today.
    public static func distanceMet(_ distancePct: Decimal?) -> Bool {
        guard let d = distancePct else { return false }
        return d <= 0
    }

    /// A level's label; a final branch says what it pays (`"At maturity ≥ this: 100%"`).
    public static func levelLabel(_ level: NoteDetail.Level) -> String {
        levelLabel(kind: level.kind, payoutPct: level.payoutPct, settlement: level.settlement)
    }

    public static func levelLabel(kind: String, payoutPct: Decimal? = nil, settlement: String? = nil) -> String {
        switch kind {
        case "final": "At maturity ≥ this: \(pct(payoutPct))\(settlement == "physical" ? " in shares" : "")"
        case "autocall": "Autocall"
        case "coupon": "Coupon barrier"
        case "break_even": "Break-even at maturity"
        default: kind
        }
    }

    /// `"Coupon paid"`, `"Not called"`.
    public static func outcomeLabel(_ kind: String) -> String {
        switch kind {
        case "coupon": "Coupon paid"
        case "coupon_missed": "Coupon missed"
        case "autocall": "Called early"
        case "autocall_missed": "Not called"
        case "maturity": "Redeemed"
        default: kind
        }
    }

    /// A paid coupon or a call is good news; misses are muted.
    public static func outcomeTone(_ kind: String) -> Tone { kind == "coupon" || kind == "autocall" ? .positive : .neutral }

    /// A branch's formula: `"100%"`, `"WP − 24.5%"`, `"1.667 × WP"`. WP is the worst share's level.
    public static func branchFormula(interceptPct: Decimal, slope: Decimal) -> String {
        if slope == 0 { return pct(interceptPct) }
        let wp = slope == 1 ? "WP" : "\(number(MoneyFormat.rounded(slope, scale: 3))) × WP"
        if interceptPct == 0 { return wp }
        return "\(wp) \(interceptPct < 0 ? "−" : "+") \(number(interceptPct < 0 ? -interceptPct : interceptPct))%"
    }

    public struct PayoutRow: Sendable, Hashable {
        public let when: String
        public let pays: String
        public let physical: Bool
    }

    /// The branches as `"worst at or above X%"` → what it pays, highest first; the last reads `"below Y%"`.
    public static func payoutRows(_ branches: [NotePayoutBranch]) -> [PayoutRow] {
        let sorted = branches.sorted { $0.minWorstPct > $1.minWorstPct }
        return sorted.enumerated().map { i, b in
            let upper = i > 0 ? sorted[i - 1].minWorstPct : nil
            let when: String
            if b.minWorstPct == 0 {
                when = upper.map { "Worst below \(pct($0))" } ?? "Any level"
            } else if let upper {
                when = "Worst \(pct(b.minWorstPct)) to \(pct(upper))"
            } else {
                when = "Worst ≥ \(pct(b.minWorstPct))"
            }
            return PayoutRow(when: when, pays: branchFormula(interceptPct: b.interceptPct, slope: b.slope),
                             physical: b.settlement == "physical")
        }
    }

    /// One observation date's schedule: coupon rate, barrier and memory; autocall trigger and amount.
    public struct ScheduleEntry: Sendable, Hashable {
        public let obsDate: CalendarDay?
        public let couponRatePct: Decimal?
        public let couponBarrierPct: Decimal?
        public let couponMemory: Bool
        public let autocallTriggerPct: Decimal?

        public init(obsDate: CalendarDay?, couponRatePct: Decimal?, couponBarrierPct: Decimal?, couponMemory: Bool,
                    autocallTriggerPct: Decimal?) {
            self.obsDate = obsDate
            self.couponRatePct = couponRatePct
            self.couponBarrierPct = couponBarrierPct
            self.couponMemory = couponMemory
            self.autocallTriggerPct = autocallTriggerPct
        }
    }

    /// The schedule in one line: `"2 coupons of 0.667% (98% barrier, memory) · 1 autocall date from
    /// 22 Apr 2027 at 105%"`.
    public static func scheduleSummary(_ entries: [ScheduleEntry]) -> String {
        func distinct(_ values: [Decimal?]) -> [Decimal?] {
            var out: [Decimal?] = []
            for v in values where !out.contains(v) { out.append(v) }
            return out
        }
        let coupons = entries.filter { $0.couponRatePct != nil }
        let calls = entries.filter { $0.autocallTriggerPct != nil }
        var parts: [String] = []
        if !coupons.isEmpty {
            let rates = distinct(coupons.map(\.couponRatePct))
            let barriers = distinct(coupons.map(\.couponBarrierPct))
            let memory = coupons.contains { $0.couponMemory }
            parts.append("\(coupons.count) coupon\(coupons.count == 1 ? "" : "s") of "
                + (rates.count == 1 ? pct(rates[0]) : "varying rates")
                + " (" + (barriers.count == 1 ? "\(pct(barriers[0])) barrier" : "varying barriers")
                + (memory ? ", memory" : "") + ")")
        }
        if !calls.isEmpty {
            let triggers = distinct(calls.map(\.autocallTriggerPct))
            let from = calls[0].obsDate.map(LedgerDates.fullDayLabel) ?? "—"
            let at = triggers.count == 1 ? pct(triggers[0]) : "\(pct(triggers[0])) stepping to \(pct(triggers[triggers.count - 1]))"
            parts.append("\(calls.count) autocall date\(calls.count == 1 ? "" : "s") from \(from) at \(at)")
        }
        return parts.isEmpty ? "No coupons or autocalls" : parts.joined(separator: " · ")
    }

    /// The payoff curve's rows worth a line: every 10%, and the points at or either side of each
    /// branch level. In the server's order (ascending worst %).
    public static func maturityTableRows(_ curve: [NoteDetail.MaturityPoint], branches: [NotePayoutBranch]) -> [NoteDetail.MaturityPoint] {
        let levels = Set(branches.map(\.minWorstPct).filter { $0 > 0 })
        return curve.enumerated().filter { i, p in
            let wp = p.worstPct
            if MoneyFormat.rounded(wp / 10, scale: 0) * 10 == wp { return true }
            let next = i + 1 < curve.count ? curve[i + 1].worstPct : nil
            return levels.contains { l in wp == l || (next.map { wp < l && $0 > l } ?? false) }
        }
        .map(\.element)
    }

    /// `"in 30 days"`, `"tomorrow"`, `"today"`.
    public static func inDays(_ days: Int) -> String {
        switch days {
        case ..<1: "today"
        case 1: "tomorrow"
        default: "in \(days) days"
        }
    }
}

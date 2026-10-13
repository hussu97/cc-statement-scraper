import Foundation

/// Overview's pace rule (PAR-6, web `PaceRule` / `lib/pace.ts`): this month's spend drawn along
/// a line, with pins where last month and the 3-month average stood by today, and the server's
/// projected month end under it. Every amount is a server field (`overview`); this type only
/// places them on a shared scale and words them (root CLAUDE.md §2.2).
public struct PaceRule: Sendable, Hashable {
    public struct Pin: Sendable, Hashable, Identifiable {
        public enum Key: String, Sendable { case prev, avg }
        public var id: Key { key }
        public let key: Key
        /// `"Last month by the 13th"`, `"3-month average by the 13th"`.
        public let label: String
        public let value: Decimal
        /// 0…1 along the rule; nil when nothing on the rule is above zero.
        public let at: Double?
        public var amountLabel: String { MoneyFormat.aed(value, fractionDigits: 0) }
    }

    public let spend: Decimal
    /// Where this month's spend reaches, 0…1; nil when nothing on the rule is above zero.
    public let spendAt: Double?
    public let pins: [Pin]
    /// `"Projected AED 9,100 by 31 Oct"`; nil without the server's projection.
    public let projection: String?

    /// The rule ends this far beyond its largest value, so the largest mark isn't on the edge.
    public static let headroom = 1.08

    public var spendLabel: String { "\(MoneyFormat.aed(spend, fractionDigits: 0)) so far" }

    /// VoiceOver reads the rule as one sentence.
    public var accessibilityLabel: String {
        let pins = pins.map { "\($0.label) \($0.amountLabel)" }.joined(separator: "; ")
        return "Spent \(MoneyFormat.aed(spend, fractionDigits: 0)) so far; \(pins)." + (projection.map { " \($0)." } ?? "")
    }

    /// Places `values` on one scale whose end is `headroom` past the largest positive value
    /// (web `placeMarks`). Display geometry only, from server figures.
    public static func positions(_ values: [Decimal]) -> [Double?] {
        let numbers = values.map(\.chartValue)
        guard let top = numbers.filter({ $0 > 0 }).max() else { return values.map { _ in nil } }
        let scale = top * headroom
        return numbers.map { min(max($0 / scale, 0), 1) }
    }

    /// `"1st"`, `"2nd"`, `"3rd"`, `"11th"`, `"13th"`, `"22nd"`.
    public static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}

extension Overview {
    /// The pace rule for the current month; nil for any other month (web: `isCurrent` only).
    /// The pins are last month by today (`spend_prev_month_to_date`) and the 3-month average by
    /// today (`spend_avg_3m_to_date`); a server without the latter gets the whole-month average,
    /// labelled as such.
    public func paceRule(today: CalendarDay = LedgerDates.today()) -> PaceRule? {
        guard isCurrentMonth(today: today) else { return nil }
        let day = "the \(PaceRule.ordinal(today.day))"
        let avg: (label: String, value: Decimal) = spendAvg3mToDate.map { ("3-month average by \(day)", $0) }
            ?? ("3-month average, whole month", spendAvg3m)
        let at = PaceRule.positions([spend, spendPrevMonthToDate, avg.value])
        let pins = [
            PaceRule.Pin(key: .prev, label: "Last month by \(day)", value: spendPrevMonthToDate, at: at[1]),
            PaceRule.Pin(key: .avg, label: avg.label, value: avg.value, at: at[2]),
        ]
        let projection = projectedMonthEnd.map {
            "Projected \(MoneyFormat.aed($0, fractionDigits: 0)) by \(LedgerDates.dayLabel(month.endOfMonth, today: today))"
        }
        return PaceRule(spend: spend, spendAt: at[0], pins: pins, projection: projection)
    }
}

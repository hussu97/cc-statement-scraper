import Foundation

/// A live note in one line (`verdict`, `20261027200000_note_verdicts.sql`): the server decides
/// what matters today (called on track, a share that must rise, a coupon at risk, the run to
/// maturity) from its evaluation; this only words it. Gaps follow the evaluator: positive = the
/// share must rise that much, zero or negative = already there. A kind this build doesn't know
/// decodes (`unknown`) and says nothing.
public struct NoteVerdict: Decodable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case onTrack, needs, couponAtRisk, toMaturity, awaitingPrices, ended
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "on_track": self = .onTrack
            case "needs": self = .needs
            case "coupon_at_risk": self = .couponAtRisk
            case "to_maturity": self = .toMaturity
            case "awaiting_prices": self = .awaitingPrices
            case "ended": self = .ended
            default: self = .unknown(raw)
            }
        }
    }

    public let kind: Kind
    /// The share it is about (the one holding the note back).
    public let symbol: String?
    public let gapPct: Decimal?
    /// The call date (`on_track`, `needs`), the coupon check (`coupon_at_risk`) or the final
    /// valuation (`to_maturity`).
    public let date: CalendarDay?
    /// `coupon_at_risk` only: what the call needs, and when.
    public let callGapPct: Decimal?
    public let callDate: CalendarDay?

    public init(kind: Kind, symbol: String? = nil, gapPct: Decimal? = nil, date: CalendarDay? = nil,
                callGapPct: Decimal? = nil, callDate: CalendarDay? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.gapPct = gapPct
        self.date = date
        self.callGapPct = callGapPct
        self.callDate = callDate
    }

    enum CodingKeys: String, CodingKey { case kind, symbol, gapPct, date, callGapPct, callDate }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(raw: try c.decodeIfPresent(String.self, forKey: .kind) ?? "")
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        gapPct = try c.decodeIfPresent(Decimal.self, forKey: .gapPct)
        date = try c.decodeIfPresent(CalendarDay.self, forKey: .date)
        callGapPct = try c.decodeIfPresent(Decimal.self, forKey: .callGapPct)
        callDate = try c.decodeIfPresent(CalendarDay.self, forKey: .callDate)
    }

    /// A rise worth waiting for: past this, `needs` reads as a warning.
    static let farGapPct: Decimal = 10

    /// `"9.3%"`: a gap, one decimal, no sign.
    static func gap(_ value: Decimal) -> String { NoteText.pct(value < 0 ? -value : value, digits: 1) }

    /// The headline: `"On track to be called on 15 Mar 2027"`, `"Called on 15 Mar 2027 if GOOGL rises 9.3%"`,
    /// `"Coupon at risk: GOOGL is 0.3% below the barrier (check 23 Nov)"`,
    /// `"Runs to Jun 2028 · capital safe while JPM stays above its break-even"`. Nil for an unknown kind.
    public func headline(today: CalendarDay = LedgerDates.today()) -> String? {
        let when = date.map { LedgerDates.dayLabel($0, today: today) }
        switch kind {
        case .onTrack:
            return when.map { "On track to be called on \($0)" } ?? "On track to be called"
        case .needs:
            guard let symbol, let gapPct, gapPct > 0 else {
                return when.map { "Next call date \($0)" } ?? "Not on track to be called yet"
            }
            return (when.map { "Called on \($0)" } ?? "Called") + " if \(symbol) rises \(Self.gap(gapPct))"
        case .couponAtRisk:
            guard let symbol, let gapPct else { return "Coupon at risk" + (when.map { " (check \($0))" } ?? "") }
            return "Coupon at risk: \(symbol) is \(Self.gap(gapPct)) below the barrier" + (when.map { " (check \($0))" } ?? "")
        case .toMaturity:
            let runs = date.map { "Runs to \(LedgerDates.shortMonthYear($0))" } ?? "Runs to maturity"
            guard let symbol, let gapPct else { return runs }
            return gapPct <= 0
                ? "\(runs) · capital safe while \(symbol) stays above its break-even"
                : "\(runs) · \(symbol) is \(Self.gap(gapPct)) below break-even"
        case .awaitingPrices:
            return "Waiting for today's prices"
        case .ended:
            return "Ended"
        case .unknown:
            return nil
        }
    }

    /// Good news is positive; a coupon at risk, or a call needing more than a 10% rise, is a
    /// warning; a note under its break-even is danger.
    public var tone: Tone {
        switch kind {
        case .onTrack: .positive
        case .needs: (gapPct ?? 0) > Self.farGapPct ? .warn : .neutral
        case .couponAtRisk: .warn
        case .toMaturity: (gapPct ?? 0) > 0 ? .danger : .neutral
        case .awaitingPrices, .ended, .unknown: .neutral
        }
    }

    /// `coupon_at_risk`'s second line: `"Called on 22 Apr 2027 if GOOGL rises 7.5%"`.
    public func callLine(today: CalendarDay = LedgerDates.today()) -> String? {
        guard kind == .couponAtRisk, let symbol, let gap = callGapPct else { return nil }
        let when = callDate.map { "Called on \(LedgerDates.dayLabel($0, today: today))" } ?? "Called"
        return gap <= 0 ? "\(when) if every stock stays at its call level" : "\(when) if \(symbol) rises \(Self.gap(gap))"
    }
}

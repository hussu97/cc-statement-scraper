import Foundation

/// A note's payout at the final valuation: the branch with the highest `minWorstPct` at or below
/// the worst share's level (WP) pays `intercept + slope × WP` % of the nominal.
public struct NotePayoutBranch: Decodable, Sendable, Hashable {
    public let minWorstPct: Decimal
    public let interceptPct: Decimal
    public let slope: Decimal
    /// `cash` or `physical` (shares of the worst share).
    public let settlement: String

    public init(minWorstPct: Decimal, interceptPct: Decimal, slope: Decimal, settlement: String = "cash") {
        self.minWorstPct = minWorstPct
        self.interceptPct = interceptPct
        self.slope = slope
        self.settlement = settlement
    }
}

/// `structured_note_detail`: the summary plus terms, schedule, payout, each share against the
/// barriers, the levels, scenarios, outcomes so far, recorded events and the price series. Every
/// figure is the server's (`private.note_evaluate`).
public struct NoteDetail: Decodable, Sendable, Hashable {
    public struct Terms: Decodable, Sendable, Hashable {
        public let guarantor: String?
        public let denomination: Decimal
        public let issuePricePct: Decimal
        public let strikeDate: CalendarDay
        public let issueDate: CalendarDay?
        public let finalValuationDate: CalendarDay
        public let maturityDate: CalendarDay
        public let termsheetPath: String?
        public let termsheetFilename: String?
    }

    public struct Observation: Decodable, Sendable, Hashable, Identifiable {
        public var id: CalendarDay { obsDate }
        public let seq: Int
        public let obsDate: CalendarDay
        public let payDate: CalendarDay
        public let couponRatePct: Decimal?
        public let couponBarrierPct: Decimal?
        public let couponMemory: Bool
        public let autocallTriggerPct: Decimal?
        public let autocallAmountPct: Decimal?
    }

    public struct Underlying: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { symbol }
        public let symbol: String
        public let name: String
        public let initial: Decimal
        public let close: Decimal?
        public let closeDate: CalendarDay?
        /// The last close in % of the initial level.
        public let perfPct: Decimal?
        public let isWorst: Bool
        /// How far from each level: positive needs a rise, negative is the room above it.
        public let toAutocallPct: Decimal?
        public let toCouponPct: Decimal?
        public let toBreakEvenPct: Decimal?
        public let autocallLevel: Decimal?
        public let couponLevel: Decimal?
        public let breakEvenLevel: Decimal?
    }

    public struct Level: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { "\(kind)-\(MoneyFormat.plain(pct))" }
        /// `autocall`, `coupon`, `final` or `break_even`.
        public let kind: String
        public let pct: Decimal
        public let date: CalendarDay
        public let distancePct: Decimal
        public let payoutPct: Decimal?
        public let settlement: String?
    }

    public struct AutocallScenario: Decodable, Sendable, Hashable, Identifiable {
        public var id: CalendarDay { obsDate }
        public let obsDate: CalendarDay
        public let payDate: CalendarDay
        public let triggerPct: Decimal
        public let redemptionPct: Decimal
        public let redemption: Decimal
        public let coupons: Decimal
        public let total: Decimal
        public let profit: Decimal
        public let returnPct: Decimal
        public let annualisedPct: Decimal?
    }

    public struct MaturityPoint: Decodable, Sendable, Hashable, Identifiable {
        public var id: Decimal { worstPct }
        public let worstPct: Decimal
        public let payoutPct: Decimal
        public let amount: Decimal
        public let settlement: String
        public let profit: Decimal
    }

    public struct Scenarios: Decodable, Sendable, Hashable {
        public struct Best: Decodable, Sendable, Hashable {
            public let total: Decimal
            public let profit: Decimal
            /// `autocall` or `maturity`.
            public let when: String?
            public let date: CalendarDay?
        }

        public struct Worst: Decodable, Sendable, Hashable {
            public let total: Decimal
            public let profit: Decimal
        }

        public let autocall: [AutocallScenario]
        public let maturity: [MaturityPoint]
        public let remainingCoupons: Decimal
        public let best: Best
        public let worst: Worst
    }

    public struct Outcome: Decodable, Sendable, Hashable {
        /// `coupon`, `coupon_missed`, `autocall`, `autocall_missed` or `maturity`.
        public let kind: String
        public let seq: Int?
        public let obsDate: CalendarDay
        public let payDate: CalendarDay
        public let worstPct: Decimal
        public let worstSymbol: String
        public let amount: Decimal?
        public let settlement: String?
    }

    public let summary: NoteSummary
    public let terms: Terms
    public let observations: [Observation]
    public let payout: [NotePayoutBranch]
    /// Missed memory coupons still owed, in % of the nominal.
    public let memoryUnpaidPct: Decimal?
    public let underlyings: [Underlying]
    public let levels: [Level]?
    public let scenarios: Scenarios?
    public let outcomes: [Outcome]
    /// Each share's closes since the strike: `[date, % of its initial level]`.
    public let series: [String: [[String]]]

    enum CodingKeys: String, CodingKey {
        case terms, observations, payout, memoryUnpaidPct, underlyings, levels, scenarios, outcomes, series
    }

    public init(from decoder: any Decoder) throws {
        summary = try NoteSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terms = try c.decode(Terms.self, forKey: .terms)
        observations = try c.decodeIfPresent([Observation].self, forKey: .observations) ?? []
        payout = try c.decodeIfPresent([NotePayoutBranch].self, forKey: .payout) ?? []
        memoryUnpaidPct = try c.decodeIfPresent(Decimal.self, forKey: .memoryUnpaidPct)
        underlyings = try c.decodeIfPresent([Underlying].self, forKey: .underlyings) ?? []
        levels = try c.decodeIfPresent([Level].self, forKey: .levels)
        scenarios = try c.decodeIfPresent(Scenarios.self, forKey: .scenarios)
        outcomes = try c.decodeIfPresent([Outcome].self, forKey: .outcomes) ?? []
        series = try c.decodeIfPresent([String: [[String]]].self, forKey: .series) ?? [:]
    }

    public var currency: String { summary.currency }
    public var isEnded: Bool { summary.isEnded }

    /// The outcomes observed on `day`, in the server's order.
    public func outcomes(on day: CalendarDay) -> [Outcome] { outcomes.filter { $0.obsDate == day } }
}

/// One share's line on the chart: its closes in % of its initial level, for drawing only.
public struct NoteSeriesLine: Sendable, Hashable, Identifiable {
    public struct Point: Sendable, Hashable {
        public let day: CalendarDay
        public let pct: Decimal
    }

    public var id: String { symbol }
    public let symbol: String
    public let points: [Point]
}

extension NoteDetail {
    /// The series as lines, in the term sheet's share order; unparseable points are skipped.
    public var seriesLines: [NoteSeriesLine] {
        let order = summary.symbols ?? []
        let symbols = order.filter { series[$0] != nil } + series.keys.filter { !order.contains($0) }.sorted()
        return symbols.map { symbol in
            let points = (series[symbol] ?? []).compactMap { pair -> NoteSeriesLine.Point? in
                guard pair.count == 2, let day = CalendarDay(iso: pair[0]), let pct = LedgerDecimal.parse(pair[1]) else {
                    return nil
                }
                return NoteSeriesLine.Point(day: day, pct: pct)
            }
            return NoteSeriesLine(symbol: symbol, points: points)
        }
        .filter { !$0.points.isEmpty }
    }
}

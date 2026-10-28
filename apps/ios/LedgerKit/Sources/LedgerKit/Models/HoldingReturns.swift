import Foundation

/// The returns card's periods (`holding_returns.p_period`).
public enum ReturnsPeriod: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case ytd
    case twelveMonths = "12m"
    case thirtyDays = "30d"
    case ninetyDays = "90d"

    public var id: String { rawValue }

    /// A holding's own screen: all time, this year, 12 months.
    public static let holding: [ReturnsPeriod] = [.all, .ytd, .twelveMonths]
    /// Investments: one choice for the value chart and the returns.
    public static let investments: [ReturnsPeriod] = [.thirtyDays, .ninetyDays, .ytd, .twelveMonths]

    /// A holding's segmented control: `"All"`, `"This year"`, `"12 months"`.
    public var title: String {
        switch self {
        case .all: "All"
        case .ytd: "This year"
        case .twelveMonths: "12 months"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        }
    }

    /// Investments' segmented control: `"30 days"`, `"90 days"`, `"YTD"`, `"365 days"`.
    public var shortTitle: String {
        switch self {
        case .all: "All"
        case .ytd: "YTD"
        case .twelveMonths: "365 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        }
    }

    /// In a sentence: `"since you started"`, `"this year"`, `"in the last 12 months"`.
    public var phrase: String {
        switch self {
        case .all: "since you started"
        case .ytd: "this year"
        case .twelveMonths: "in the last 12 months"
        case .thirtyDays: "in the last 30 days"
        case .ninetyDays: "in the last 90 days"
        }
    }

    /// The days the server's returns cover (`holding_returns`' `from` to today), for the value
    /// chart to draw the same span; nil for all time.
    public func range(today: CalendarDay) -> (from: CalendarDay, to: CalendarDay)? {
        switch self {
        case .all: nil
        case .ytd: (CalendarDay(year: today.year, month: 1, day: 1), today)
        case .twelveMonths: (today.adding(days: -365), today)
        case .thirtyDays: (today.adding(days: -30), today)
        case .ninetyDays: (today.adding(days: -90), today)
        }
    }
}

/// What a period's figures are, for one holding or the total. Every figure is the server's (AED):
/// growth = end − start − added + income, simple % and the money-weighted yearly rate (XIRR).
public struct ReturnFigures: Decodable, Sendable, Hashable {
    /// Nil when the value at the period's start is unknown (no price or value then).
    public let startValueAed: Decimal?
    public let endValueAed: Decimal?
    /// Money in − money out during the period.
    public let addedAed: Decimal?
    public let incomeAed: Decimal?
    public let growthAed: Decimal?
    public let simplePct: Decimal?
    /// Nil under 90 days of history (or with no change of sign to solve for).
    public let annualPct: Decimal?
    /// The start value is known; an incomplete holding stays out of the total.
    public let complete: Bool

    public init(startValueAed: Decimal? = 0, endValueAed: Decimal? = nil, addedAed: Decimal? = nil,
                incomeAed: Decimal? = nil, growthAed: Decimal? = nil, simplePct: Decimal? = nil,
                annualPct: Decimal? = nil, complete: Bool = true) {
        self.startValueAed = startValueAed
        self.endValueAed = endValueAed
        self.addedAed = addedAed
        self.incomeAed = incomeAed
        self.growthAed = growthAed
        self.simplePct = simplePct
        self.annualPct = annualPct
        self.complete = complete
    }

    /// One line of the card: a label, the figure and its tone.
    public struct Line: Sendable, Hashable, Identifiable {
        public var id: String { label }
        public let label: String
        public let text: String
        public let tone: Tone
    }

    /// `Value at start`, `Money added`, `Income`, `Growth`, `Return`, `A year`; only what is known.
    public func lines(period: ReturnsPeriod) -> [Line] {
        var out: [Line] = []
        if period != .all, let start = startValueAed { out.append(Line(label: "Value at start", text: MoneyFormat.aed(start), tone: .neutral)) }
        if let added = addedAed { out.append(Line(label: "Money added", text: HoldingsText.signedAed(added), tone: .neutral)) }
        if let income = incomeAed, income != 0 {
            out.append(Line(label: "Income", text: MoneyFormat.aed(income), tone: .positive))
        }
        if let end = endValueAed { out.append(Line(label: "Value now", text: MoneyFormat.aed(end), tone: .neutral)) }
        if let growth = growthAed {
            out.append(Line(label: "Growth", text: HoldingsText.signedAed(growth), tone: HoldingsText.tone(growth)))
        }
        if let pct = simplePct {
            out.append(Line(label: "Return", text: HoldingsText.signedPercent(pct), tone: HoldingsText.tone(pct)))
        }
        return out
    }

    /// `"+14.52%"`; nil without a yearly rate.
    public var annualText: String? { annualPct.map(HoldingsText.signedPercent) }
    /// The yearly rate's label.
    public static let annualLabel = "Yearly return"
    public var annualTone: Tone { HoldingsText.tone(annualPct) }

    /// Instead of the yearly rate.
    public static let noAnnualNote = "A yearly rate shows once there are 90 days of history."
    /// What the yearly rate is.
    public static let annualNote =
        "Money-weighted: each payment in or out counts from its own date, so new money isn't mistaken for growth."
}

/// One holding's figures in `holding_returns.holdings`.
public struct HoldingReturn: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let name: String
    public let kind: HoldingKind
    public let from: CalendarDay?
    public let to: CalendarDay?
    public let figures: ReturnFigures

    public init(holdingCode: String, name: String, kind: HoldingKind, from: CalendarDay? = nil, to: CalendarDay? = nil,
                figures: ReturnFigures) {
        self.holdingCode = holdingCode
        self.name = name
        self.kind = kind
        self.from = from
        self.to = to
        self.figures = figures
    }

    enum CodingKeys: String, CodingKey { case holdingCode, name, kind, from, to }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        holdingCode = try c.decode(String.self, forKey: .holdingCode)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(HoldingKind.self, forKey: .kind) ?? .metal
        from = try c.decodeIfPresent(CalendarDay.self, forKey: .from)
        to = try c.decodeIfPresent(CalendarDay.self, forKey: .to)
        figures = try ReturnFigures(from: decoder)
    }

    /// Why a holding has no return for the period: for all time, no money recorded going in (its
    /// cost is unknown); for this year or 12 months, no value at the period's start.
    public static func incompleteNote(period: ReturnsPeriod) -> String {
        period == .all
            ? "No money recorded going in, so no return for it. Add what you paid to count it."
            : "No value at the start of this period, so no return for it."
    }
}

/// `rpc('holding_returns')`: per holding and in total, for one period.
public struct HoldingReturns: Decodable, Sendable, Hashable {
    public let period: String
    /// Nil for all time.
    public let from: CalendarDay?
    public let to: CalendarDay?
    public let total: ReturnFigures
    public let holdings: [HoldingReturn]

    public init(period: ReturnsPeriod, from: CalendarDay? = nil, to: CalendarDay? = nil, total: ReturnFigures,
                holdings: [HoldingReturn] = []) {
        self.period = period.rawValue
        self.from = from
        self.to = to
        self.total = total
        self.holdings = holdings
    }

    /// The holdings left out of the total for want of a start value.
    public var incomplete: [HoldingReturn] { holdings.filter { !$0.figures.complete } }

    /// What the total leaves out, and why. All time: `"Left out: Bangles has no money recorded going
    /// in, so the total covers the rest."`; a period: `"Left out: 1 kg bar and IBKR account had no
    /// value on 1 Jan 2026, so the total covers the rest."`
    public var incompleteNote: String? {
        let names = incomplete.map(\.name)
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        guard let from else {
            return "Left out: \(list) \(names.count == 1 ? "has" : "have") no money recorded going in, so the total covers the rest."
        }
        return "Left out: \(list) had no value on \(LedgerDates.fullDayLabel(from)), so the total covers the rest."
    }

    /// The row for one holding; nil when the server didn't send it.
    public func figures(for holdingCode: String) -> HoldingReturn? { holdings.first { $0.holdingCode == holdingCode } }

    /// `"Since 1 Jan 2026"`, `"All time"`.
    public var rangeText: String { from.map { "Since " + LedgerDates.fullDayLabel($0) } ?? "All time" }
}

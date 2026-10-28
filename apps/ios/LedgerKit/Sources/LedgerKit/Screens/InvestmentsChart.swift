import Foundation

/// The Investments value chart: the holdings' value against their cost over the period on screen.
public enum InvestmentsChart {
    /// Under the chart.
    public static let note =
        "The holdings you had each day, at that day's prices and values, against what they had cost to date."

    /// The span in words: `"the last 90 days"`, `"this year"`, `"the last 365 days"`.
    public static func span(_ period: ReturnsPeriod) -> String {
        switch period {
        case .all: "all time"
        case .ytd: "this year"
        default: "the last \(period.shortTitle)"
        }
    }

    /// A card's header beside its title: `"Last 90 days"`, `"This year"`.
    public static func spanTitle(_ period: ReturnsPeriod) -> String {
        (span(period).hasPrefix("the ") ? String(span(period).dropFirst(4)) : span(period)).capitalizedFirst
    }

    /// The value chart's known days, oldest first.
    public static func known(_ points: [HoldingValuePoint]) -> [HoldingValuePoint] {
        points.filter { $0.valueAed != nil }.sorted { $0.date < $1.date }
    }

    /// A y-axis tick (a chart position, not money): compact AED (`"650k"`, `"496"`), or two
    /// decimals under 100, where silver's price per gram moves in fils (`"7.96"`).
    public static func axisLabel(_ tick: Double) -> String {
        if abs(tick) < 100 { return MoneyFormat.grouped(Decimal(Int((tick * 100).rounded())) / 100, fractionDigits: 2) }
        return MoneyFormat.compact(Decimal(Int(tick.rounded())))
    }

    /// Under the value chart when some days leave out a holding with no value yet; nil otherwise.
    public static func partialNote(_ points: [HoldingValuePoint]) -> String? {
        known(points).contains { !$0.complete }
            ? "Some days leave out a holding that had no price or value yet." : nil
    }

    /// Instead of a chart: two known days make a line.
    public static let tooFewMessage = "Not enough price history yet: a line shows from the second day of prices."
}


import Foundation

/// What the Investments chart draws: the holdings' value against their cost, or a price.
public enum InvestmentsChart: String, CaseIterable, Identifiable, Hashable, Sendable {
    case value, gold24k, silver

    public var id: String { rawValue }

    /// The segmented control: `"Value"`, `"24K gold"`, `"Silver"`.
    public var title: String {
        switch self {
        case .value: "Value"
        case .gold24k: "24K gold"
        case .silver: "Silver"
        }
    }

    /// The price series behind a price chart; nil for the value chart.
    public var quote: MetalQuote? {
        switch self {
        case .value: nil
        case .gold24k: .gold24k
        case .silver: .silverRetail
        }
    }

    /// Under the chart.
    public var note: String {
        switch self {
        case .value:
            "The holdings you had each day, at that day's prices and values, against what they had cost to date."
        case .gold24k: "Dubai retail 24K gold (999.9), AED per gram, each day's last price."
        case .silver: "Dubai retail silver, AED per gram, each day's last price."
        }
    }

    /// How many days every chart covers.
    public static let days = 90

    /// The value chart's known days, oldest first.
    public static func known(_ points: [HoldingValuePoint]) -> [HoldingValuePoint] {
        points.filter { $0.valueAed != nil }.sorted { $0.date < $1.date }
    }

    /// A price chart's known days, oldest first.
    public static func known(_ points: [MetalPricePoint]) -> [MetalPricePoint] {
        points.filter { $0.aedPerGram != nil }.sorted { $0.date < $1.date }
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


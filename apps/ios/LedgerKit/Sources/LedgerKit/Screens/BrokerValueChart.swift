import Foundation

/// The broker account's value per day against the money put in to date (`broker_portfolio.series`).
/// Days rebuilt from the broker's performance index (`estimated`) are drawn apart from the synced
/// ones: the value line is cut into runs of one kind, each run starting at the previous run's last
/// day so the line stays joined. Every point is the server's.
public struct BrokerValueChart: Sendable, Hashable {
    /// One point of the value line, in its run.
    public struct ValueMark: Sendable, Hashable, Identifiable {
        public var id: String { "\(run)-\(day.iso)" }
        public let day: CalendarDay
        public let value: Decimal
        /// The run's series name (`"run-0"`): one line per run, so two estimated runs never join.
        public let run: String
        public let estimated: Bool
    }

    public struct DepositMark: Sendable, Hashable, Identifiable {
        public var id: CalendarDay { day }
        public let day: CalendarDay
        public let value: Decimal
    }

    public let values: [ValueMark]
    public let deposits: [DepositMark]
    private let points: [BrokerPortfolio.Point]
    private let currency: String

    public init(_ series: [BrokerPortfolio.Point], currency: String) {
        let sorted = series.sorted { $0.asOf < $1.asOf }
        points = sorted
        self.currency = currency
        var marks: [ValueMark] = []
        var run = -1
        var previous: BrokerPortfolio.Point?
        for p in sorted {
            if previous?.estimated != p.estimated {
                run += 1
                // The new run starts where the last one ended, so the line has no gap.
                if let previous {
                    marks.append(ValueMark(day: previous.asOf, value: previous.total, run: "run-\(run)", estimated: p.estimated))
                }
            }
            marks.append(ValueMark(day: p.asOf, value: p.total, run: "run-\(run)", estimated: p.estimated))
            previous = p
        }
        values = marks
        deposits = sorted.map { DepositMark(day: $0.asOf, value: $0.netDeposits) }
    }

    /// Two days make a line.
    public var showsChart: Bool { points.count >= 2 }

    public var hasEstimated: Bool { points.contains(where: \.estimated) }

    /// The legend's words.
    public static let valueLabel = "Value"
    public static let estimatedLabel = "Value (rebuilt)"
    public static let depositsLabel = "Net deposits"

    /// Under the chart.
    public var note: String {
        guard showsChart else { return "The chart fills in as the daily syncs come in." }
        guard hasEstimated, let first = points.first(where: \.estimated)?.asOf,
              let last = points.last(where: \.estimated)?.asOf else {
            return "The account's value each day against the money put in to date."
        }
        return "The account's value each day against the money put in to date. Dashed: rebuilt from the broker's "
            + "performance index (\(LedgerDates.fullDayLabel(first)) to \(LedgerDates.fullDayLabel(last))), before daily syncs."
    }

    /// `"Oct ’25"`: an x-axis tick over a span of years.
    public static func axisLabel(_ day: CalendarDay) -> String {
        "\(LedgerDates.monthAbbrev(day)) ’\(String(format: "%02d", day.year % 100))"
    }

    /// `"27 Oct 2026: USD 113,674.26 against USD 95,000.00 put in"` for VoiceOver.
    public var accessibilityValue: String {
        guard let last = points.last else { return "No history yet" }
        return "\(LedgerDates.fullDayLabel(last.asOf)): \(MoneyFormat.amount(last.total, currency: currency)) "
            + "against \(MoneyFormat.amount(last.netDeposits, currency: currency)) put in"
    }
}

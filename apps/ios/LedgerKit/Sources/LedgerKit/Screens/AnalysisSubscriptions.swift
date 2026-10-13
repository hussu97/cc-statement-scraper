import Foundation

/// The full `recurring_list` in words (web `SubscriptionsTab`, BACKLOG PAR-12): active charges
/// and the ended or dismissed ones, in the server's order. Every amount is the server's.
public struct SubscriptionList: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String { charge.recurringCode }
        public let charge: RecurringCharge
        public let today: CalendarDay

        public var merchantName: String { charge.merchantName }
        public var isActive: Bool { charge.status == "active" }
        /// `"Ended"` / `"Dismissed"` for a charge that no longer counts; nil when active.
        public var statusBadge: String? { isActive ? nil : charge.status == "ended" ? "Ended" : "Dismissed" }
        /// `"Monthly · Streaming · 5 charges"`.
        public var detail: String {
            [SubscriptionList.cadenceLabel(charge.cadence), charge.categoryName,
             AnalysisFormat.count(charge.occurrences, "charge")].compactMap { $0 }.joined(separator: " · ")
        }
        /// `"AED 45.00 / month"`.
        public var expectedLabel: String {
            "\(MoneyFormat.aed(charge.expectedAmount)) / \(SubscriptionList.per[charge.cadence] ?? "time")"
        }
        /// `"Last AED 49.00"`.
        public var lastLabel: String { "Last \(MoneyFormat.aed(charge.lastAmount))" }
        /// The last charge against the usual one (web `priceChangeBadge`).
        public var priceChange: AnalysisChip? { SubscriptionList.priceChangeBadge(charge.priceChange) }
        /// An active charge whose next one is due before today and hasn't been seen.
        public var isOverdue: Bool { isActive && (charge.nextExpected.map { $0 < today } ?? false) }
        /// `"Next 2 Nov"`, `"Expected 2 Oct, not seen yet"`, or `"Last charged 3 Oct"` once it ended.
        public var whenLabel: String {
            if !isActive { return "Last charged \(LedgerDates.dayLabel(charge.lastDate, today: today))" }
            guard let next = charge.nextExpected else { return "—" }
            let day = LedgerDates.dayLabel(next, today: today)
            return isOverdue ? "Expected \(day), not seen yet" : "Next \(day)"
        }
        /// `"AED 540 a year"`: the server's `annual_cost`.
        public var annualLabel: String { "\(AnalysisFormat.total(charge.annualCost)) a year" }
    }

    public let rows: [Row]

    public init(_ charges: [RecurringCharge], today: CalendarDay = LedgerDates.today()) {
        rows = charges.map { Row(charge: $0, today: today) }
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var activeCount: Int { rows.filter(\.isActive).count }

    /// `"3 active charges · 1 ended or dismissed"` (web's card eyebrow).
    public var headline: String {
        let inactive = rows.count - activeCount
        return [AnalysisFormat.count(activeCount, "active charge"),
                inactive > 0 ? "\(inactive) ended or dismissed" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    public static let title = "Subscriptions"
    public static let footnote = "Spotted from 3 or more charges at a steady interval. Annual cost is the expected charge over a year."
    public static let emptyTitle = "Nothing recurring found yet"
    public static let emptyBody = "Bank Ledger needs 3 charges at a steady interval from the same merchant before it calls something a subscription."

    static let per = ["weekly": "week", "monthly": "month", "yearly": "year"]

    /// `"Weekly"`, `"Monthly"`, `"Yearly"`; nil for a cadence the app doesn't know.
    public static func cadenceLabel(_ cadence: String) -> String? {
        ["weekly": "Weekly", "monthly": "Monthly", "yearly": "Yearly"][cadence]
    }

    /// The server's price-change ratio (0.12 = +12 %) as a badge: up is a warning, down good
    /// news; under half a percent is noise and gets none (web `priceChangeBadge`).
    public static func priceChangeBadge(_ ratio: Decimal?) -> AnalysisChip? {
        guard let ratio else { return nil }
        let magnitude = ratio < 0 ? -ratio : ratio
        guard magnitude >= Decimal(string: "0.005")! else { return nil }
        let pct = MoneyFormat.rounded(magnitude * 100, scale: 0)
        let figure = pct == 0 ? "<1" : MoneyFormat.grouped(pct, fractionDigits: 0)
        return ratio > 0 ? AnalysisChip("+\(figure)%", .warn) : AnalysisChip("−\(figure)%", .positive)
    }
}

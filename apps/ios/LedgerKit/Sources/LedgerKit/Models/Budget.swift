import Foundation

/// A budget's name from its scope, the same rule as the web's `budgetTitle` and
/// the server's budget insights: the category (nil: `"All spending"`), and for a
/// card budget the card: `"Daily card"` for all its spending, else
/// `"Dining · Daily card"`.
public enum BudgetScope {
    public static func title(categoryName: String?, accountName: String?) -> String {
        guard let accountName else { return categoryName ?? "All spending" }
        guard let categoryName else { return accountName }
        return "\(categoryName) · \(accountName)"
    }
}

/// Where a month sits against today's: it decides the pace line and which
/// month a new budget starts in.
public enum BudgetMonthPhase: Sendable, Equatable {
    case past, current, future

    public init(month: CalendarDay, today: CalendarDay = LedgerDates.today()) {
        let m = month.startOfMonth, t = today.startOfMonth
        self = m < t ? .past : m > t ? .future : .current
    }
}

extension BudgetStatus {
    /// The meter tone, from the server's figures (same rule as the web):
    /// over budget is danger; 80%+ used, or on pace to overspend in the
    /// current month, is a warning.
    public func tone(isCurrentMonth: Bool) -> Tone {
        if shareUsed > 1 { return .danger }
        if shareUsed >= Decimal(string: "0.8")! { return .warn }
        if isCurrentMonth && isProjectedOver { return .warn }
        return .positive
    }

    public var progressFraction: Double { min(max(shareUsed.chartValue, 0), 1) }

    /// `"AED 1,200 of AED 2,000"`.
    public var progressLabel: String {
        "\(MoneyFormat.aed(spentAed, fractionDigits: 0)) of \(MoneyFormat.aed(budgetAed, fractionDigits: 0))"
    }

    /// `"42% used"`, the server's `share_used`.
    public var usedLabel: String { "\(MoneyFormat.percent(shareUsed)) used" }

    /// The pace line (web `budgetPace`): in the current month, how far spend is from the
    /// budget's even share by today and the server's projection,
    /// `"AED 120 over pace · projected AED 2,481"` (`"Projected AED 2,481"` from a server
    /// without `over_pace_aed`); otherwise whether the month is over or still to come.
    public func paceLabel(_ phase: BudgetMonthPhase) -> String {
        switch phase {
        case .current:
            let projected = MoneyFormat.aed(projectedAed, fractionDigits: 0)
            return overPaceLabel.map { "\($0) · projected \(projected)" } ?? "Projected \(projected)"
        case .past: return "Month closed"
        case .future: return "Month not started"
        }
    }

    /// `"AED 120 over pace"`, `"AED 80 under pace"` or `"On pace"`, from the server's
    /// `over_pace_aed` (spent − expected by today); nil outside the current month.
    public var overPaceLabel: String? {
        guard let overPaceAed else { return nil }
        if overPaceAed > 0 { return "\(MoneyFormat.aed(overPaceAed, fractionDigits: 0)) over pace" }
        if overPaceAed < 0 { return "\(MoneyFormat.aed(-overPaceAed, fractionDigits: 0)) under pace" }
        return "On pace"
    }

    /// The pace line is a warning: spent more than the even share by today (the server's
    /// `over_pace_aed`, positive exactly when the month is on pace to overspend), or, from an
    /// older server, projected over budget.
    public func isOverPace(_ phase: BudgetMonthPhase) -> Bool {
        guard phase == .current else { return false }
        return overPaceAed.map { $0 > 0 } ?? isProjectedOver
    }

    /// Where the meter's "expected by today" tick sits (0…1), in the current month only.
    public func paceTick(_ phase: BudgetMonthPhase) -> Double? {
        guard phase == .current, let expectedShare else { return nil }
        return min(max(expectedShare.chartValue, 0), 1)
    }

    /// VoiceOver for the meter: `"42% of Groceries budget used"`, and in the current month
    /// `"…; 45% expected by today (AED 900)"`.
    public func meterAccessibilityLabel(_ phase: BudgetMonthPhase) -> String {
        let used = "\(MoneyFormat.percent(shareUsed)) of \(title) budget used"
        guard phase == .current, let expectedShare else { return used }
        let amount = expectedAed.map { " (\(MoneyFormat.aed($0, fractionDigits: 0)))" } ?? ""
        return "\(used); \(MoneyFormat.percent(expectedShare)) expected by today\(amount)"
    }

    /// Why a budget the server marked not effective for `month` doesn't count
    /// (web `inactiveBudgetLabel`): it starts later, it ended, or, when its own
    /// range does cover the month, a newer budget of the same scope replaced it.
    /// `"Starts November 2026"`, `"Ended August 2026"`, `"Replaced by a newer budget"`.
    public func inactiveLabel(month: CalendarDay) -> String {
        let m = month.startOfMonth
        if let from = effectiveFrom, from > m { return "Starts \(LedgerDates.monthTitle(from))" }
        if let to = effectiveTo, to < m { return "Ended \(LedgerDates.monthTitle(to))" }
        return "Replaced by a newer budget"
    }
}

import Foundation

/// A row of `public.budgets`: a monthly limit for all spending (no category)
/// or one category, on every card (no account) or one card, from
/// `effectiveFrom` (a first of month) through `effectiveTo` (the last month it
/// applies; nil: open-ended).
public struct Budget: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { budgetCode }
    public let budgetCode: String
    public let categoryCode: String?
    public let amountAed: Decimal
    public let effectiveFrom: CalendarDay
    public let effectiveTo: CalendarDay?
    /// The one card (account) it counts; nil: every card.
    public let accountCode: String?

    public init(budgetCode: String, categoryCode: String?, amountAed: Decimal, effectiveFrom: CalendarDay,
                effectiveTo: CalendarDay?, accountCode: String? = nil) {
        self.budgetCode = budgetCode
        self.categoryCode = categoryCode
        self.amountAed = amountAed
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.accountCode = accountCode
    }

    public var isTotal: Bool { categoryCode == nil }

    /// Whether the budget covers `month` (any day of it).
    public func applies(to month: CalendarDay) -> Bool {
        let m = month.startOfMonth
        return effectiveFrom <= m && (effectiveTo.map { $0 >= m } ?? true)
    }

    /// Why a budget that `budget_status` didn't return for `month` is not
    /// active then: `"Starts November 2026"`, `"Ended August 2026"`, or
    /// `"Replaced by a newer budget"` (a later budget of the same scope wins).
    public func inactiveLabel(month: CalendarDay) -> String {
        let m = month.startOfMonth
        if effectiveFrom > m { return "Starts \(LedgerDates.monthTitle(effectiveFrom))" }
        if let to = effectiveTo, to < m { return "Ended \(LedgerDates.monthTitle(to))" }
        return applies(to: m) ? "Replaced by a newer budget" : ""
    }
}

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

    /// The pace line: the server's projection in the current month,
    /// otherwise whether the month is over or still to come.
    public func paceLabel(_ phase: BudgetMonthPhase) -> String {
        switch phase {
        case .current: "On pace for \(MoneyFormat.aed(projectedAed, fractionDigits: 0))"
        case .past: "Month closed"
        case .future: "Month not started"
        }
    }

    /// The pace line is a warning: the current month is on pace to overspend.
    public func isOverPace(_ phase: BudgetMonthPhase) -> Bool { phase == .current && isProjectedOver }

    /// VoiceOver for the meter: `"42% of Groceries budget used"`.
    public var meterAccessibilityLabel: String { "\(MoneyFormat.percent(shareUsed)) of \(title) budget used" }
}

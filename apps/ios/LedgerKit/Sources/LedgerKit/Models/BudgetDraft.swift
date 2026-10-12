import Foundation

/// The create / edit budget form. Same rules and wording as the web's
/// `validateBudget` (apps/web/src/data/budgets.ts); the amount stays the text
/// the person typed and goes to PostgREST as a decimal string.
public struct BudgetDraft: Sendable, Hashable, Identifiable {
    public var id: String { budgetCode ?? "new" }
    /// nil: a new budget.
    public let budgetCode: String?
    /// nil: every card.
    public var accountCode: String?
    /// nil: all spending.
    public var categoryCode: String?
    public var amount: String
    /// First of a month.
    public var effectiveFrom: CalendarDay
    /// The last month it applies (first of that month); nil: no end.
    public var effectiveTo: CalendarDay?

    public init(budgetCode: String? = nil, accountCode: String? = nil, categoryCode: String? = nil,
                amount: String = "", effectiveFrom: CalendarDay, effectiveTo: CalendarDay? = nil) {
        self.budgetCode = budgetCode
        self.accountCode = accountCode
        self.categoryCode = categoryCode
        self.amount = amount
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
    }

    /// Editing an existing budget: the stored amount as plain digits.
    public init(budget: Budget) {
        self.init(budgetCode: budget.budgetCode, accountCode: budget.accountCode, categoryCode: budget.categoryCode,
                  amount: MoneyFormat.plain(budget.amountAed), effectiveFrom: budget.effectiveFrom,
                  effectiveTo: budget.effectiveTo)
    }

    /// A new budget for the month on screen; a past month's budget would only
    /// rewrite history, so it starts this month instead (as on the web).
    public static func new(month: CalendarDay, today: CalendarDay = LedgerDates.today()) -> BudgetDraft {
        let start = BudgetMonthPhase(month: month, today: today) == .past ? today.startOfMonth : month.startOfMonth
        return BudgetDraft(effectiveFrom: start)
    }

    public var isNew: Bool { budgetCode == nil }
    public var title: String { isNew ? "New budget" : "Edit budget" }
    public var saveLabel: String { isNew ? "Create budget" : "Save changes" }

    /// What is sent: grouping commas and spaces removed.
    public var normalizedAmount: String {
        amount.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// An error sentence, or nil when the draft can be saved.
    public func validate() -> String? {
        let raw = normalizedAmount
        guard Self.isAmount(raw), let value = LedgerDecimal.parse(raw), value > 0 else {
            return "Enter an amount above zero, e.g. 1500 or 1500.50."
        }
        if effectiveFrom.day != 1 { return "A budget starts on the first of a month." }
        if let to = effectiveTo, to < effectiveFrom { return "The end month must be after the start month." }
        return nil
    }

    /// `digits(.d{1,2})?`: no sign, exponent or third decimal.
    static func isAmount(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty, parts[0].allSatisfy(\.isASCIIDigit) else { return false }
        if parts.count == 2 {
            return (1...2).contains(parts[1].count) && parts[1].allSatisfy(\.isASCIIDigit)
        }
        return true
    }

    /// `"Budget created. Applies from October 2026."`
    public var savedMessage: String {
        "\(isNew ? "Budget created" : "Budget updated"). Applies from \(LedgerDates.monthTitle(effectiveFrom))."
    }

    /// Months the Starts picker offers: two years either side of today, plus
    /// the draft's own month when it is further out.
    public func startChoices(today: CalendarDay = LedgerDates.today()) -> [CalendarDay] {
        let t = today.startOfMonth
        var months = (-24...24).map { t.adding(months: $0) }
        if !months.contains(effectiveFrom) { months.append(effectiveFrom) }
        return months.sorted()
    }

    /// Months the Ends picker offers: from the start month on, two years past
    /// today (or past the start), plus the draft's own end month.
    public func endChoices(today: CalendarDay = LedgerDates.today()) -> [CalendarDay] {
        let last = max(today.startOfMonth, effectiveFrom).adding(months: 24)
        var months: [CalendarDay] = []
        var m = effectiveFrom
        while m <= last {
            months.append(m)
            m = m.adding(months: 1)
        }
        if let to = effectiveTo, !months.contains(to) { months.append(to) }
        return months.sorted()
    }

    /// Moving the start past the end clears the end (the picker can't show it).
    public mutating func setStart(_ month: CalendarDay) {
        effectiveFrom = month.startOfMonth
        if let to = effectiveTo, to < effectiveFrom { effectiveTo = nil }
    }
}

/// A card the budget form offers: the profile's active accounts (plus the
/// budget's own card, even if closed since), named as the server names them, in
/// the server's order (by bank).
public struct BudgetCardChoice: Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    public let bankCode: String
    public let label: String

    public static func choices(from accounts: [LedgerAccount], keeping current: String?) -> [BudgetCardChoice] {
        accounts.filter { $0.isActive || $0.accountCode == current }.map {
            BudgetCardChoice(accountCode: $0.accountCode, bankCode: $0.bankCode, label: $0.label)
        }
    }
}

/// A category the budget form offers: spend and fee categories that aren't
/// archived (plus the budget's own, whatever it is), parents first with their
/// children indented under them, in the server's order.
public struct BudgetCategoryChoice: Sendable, Hashable, Identifiable {
    public var id: String { categoryCode }
    public let categoryCode: String
    public let name: String
    public let colorToken: String?
    /// 0: top level; 1: a child of the row above.
    public let depth: Int

    static let pickableKinds: Set<String> = ["spend", "fee"]

    public static func choices(from options: [FilterMeta.CategoryOption], keeping current: String?) -> [BudgetCategoryChoice] {
        let list = options.filter {
            (!$0.archived && pickableKinds.contains($0.kind)) || $0.categoryCode == current
        }
        let codes = Set(list.map(\.categoryCode))
        func parent(_ c: FilterMeta.CategoryOption) -> String? {
            c.parentCode.flatMap { codes.contains($0) ? $0 : nil }
        }
        var out: [BudgetCategoryChoice] = []
        for top in list where parent(top) == nil {
            out.append(.init(categoryCode: top.categoryCode, name: top.name, colorToken: top.colorToken, depth: 0))
            for child in list where parent(child) == top.categoryCode {
                out.append(.init(categoryCode: child.categoryCode, name: child.name, colorToken: child.colorToken, depth: 1))
            }
        }
        return out
    }
}

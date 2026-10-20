import Foundation

/// One row of `rpc('cash_flow')`: a month's total for one flow, or its `net` row. PostgREST sends
/// `amount_aed` (numeric) as a JSON number, which `Decimal` decodes digit for digit.
public struct CashFlowRow: Decodable, Sendable, Hashable {
    public let month: CalendarDay
    public let flow: String
    public let amountAed: Decimal
    public let txnCount: Int
    /// The month starts before the first bank evidence (Wealth mode): it holds card spend and no
    /// captured income, so its net is not a loss. Absent from older servers: false.
    public let isPartial: Bool

    public init(month: CalendarDay, flow: String, amountAed: Decimal, txnCount: Int, isPartial: Bool = false) {
        self.month = month
        self.flow = flow
        self.amountAed = amountAed
        self.txnCount = txnCount
        self.isPartial = isPartial
    }

    enum CodingKeys: String, CodingKey { case month, flow, amountAed, txnCount, isPartial }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(CalendarDay.self, forKey: .month)
        flow = try c.decode(String.self, forKey: .flow)
        amountAed = try c.decode(Decimal.self, forKey: .amountAed)
        txnCount = try c.decode(Int.self, forKey: .txnCount)
        isPartial = try c.decodeIfPresent(Bool.self, forKey: .isPartial) ?? false
    }
}

/// The cash-flow flows as one word or two, for a ledger row's chip, in the same vocabulary as the
/// Cash flow screen's groups (`CashFlowGroupKind`) and lines (`CashFlowLine.label`).
public enum CashFlowFlow {
    public static func chipLabel(_ flow: String) -> String {
        switch flow {
        case "income": "Income"
        case "money_in": "Unfiled in"
        case "internal_in": "From own account"
        case "internal_out": "To own account"
        case "card_repayment": "Card repayment"
        case "support": "Support"
        case "saving": "Saving"
        case "spend": "Spending"
        case "spend_transfer": "Paid by transfer"
        case "money_out": "Unfiled out"
        default: flow.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Income is good news; an unfiled row asks to be filed; the rest is information.
    public static func tone(_ flow: String) -> Tone {
        switch flow {
        case "income": .positive
        case "money_in", "money_out": .warn
        case "support", "saving": .info
        default: .neutral
        }
    }

    /// The Cash flow group a flow is listed under; nil for one this build doesn't know.
    public static func group(of flow: String) -> CashFlowGroupKind? {
        CashFlowGroupKind.allCases.first { $0.flows.contains(flow) }
    }
}

/// The groups the Cash screen shows a month's flows in. Net is the server's own row; a group
/// carries no subtotal of its own (CLAUDE.md §2.2).
public enum CashFlowGroupKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case moneyIn, committed, spent, unfiledOut, moves

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .moneyIn: "Money in"
        case .committed: "Committed"
        case .spent: "Spent"
        case .unfiledOut: "Unfiled out"
        case .moves: "Moves"
        }
    }

    /// The server's flows in this group, in the order they are listed.
    public var flows: [String] {
        switch self {
        case .moneyIn: ["income", "money_in"]
        case .committed: ["support", "saving"]
        case .spent: ["spend", "spend_transfer"]
        case .unfiledOut: ["money_out"]
        case .moves: ["card_repayment", "internal_in", "internal_out"]
        }
    }

    /// A line under the group's lines; only Moves has one.
    public var note: String? {
        self == .moves ? "Card repayments and moves between your own accounts don't change net." : nil
    }

    /// Money in reads as positive; the rest is money going out (or moving).
    public var tone: Tone {
        switch self {
        case .moneyIn: .positive
        case .unfiledOut: .warn
        default: .neutral
        }
    }
}

/// One flow's line: `"Salary and other income · AED 50,000.00 · 1 transaction"`.
public struct CashFlowLine: Sendable, Hashable, Identifiable {
    public var id: String { flow }
    public let flow: String
    public let amountAed: Decimal
    public let txnCount: Int

    public var label: String { Self.label(for: flow) }
    public var amountText: String { MoneyFormat.aed(amountAed) }
    public var countText: String { txnCount == 1 ? "1 transaction" : "\(txnCount) transactions" }

    public static func label(for flow: String) -> String {
        switch flow {
        case "income": "Income"
        case "money_in": "Other money in, not filed"
        case "support": "Support"
        case "saving": "Saving & investing"
        case "spend": "Card spending"
        case "spend_transfer": "Paid by transfer"
        case "money_out": "Money out, not filed"
        case "card_repayment": "Card repayments"
        case "internal_in": "From your other accounts"
        case "internal_out": "To your other accounts"
        default: flow.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public struct CashFlowGroup: Sendable, Hashable, Identifiable {
    public var id: CashFlowGroupKind { kind }
    public let kind: CashFlowGroupKind
    public let lines: [CashFlowLine]
}

/// A month of cash flow: its groups (only those with a line) and the server's net.
public struct CashFlowMonth: Sendable, Hashable, Identifiable {
    public var id: CalendarDay { month }
    public let month: CalendarDay
    public let groups: [CashFlowGroup]
    /// The server's `net` row; nil when it sent none.
    public let net: Decimal?
    /// Before the first bank evidence (`is_partial`): its net is shown as partial, never a loss.
    public let isPartial: Bool

    public init(month: CalendarDay, groups: [CashFlowGroup], net: Decimal?, isPartial: Bool = false) {
        self.month = month
        self.groups = groups
        self.net = net
        self.isPartial = isPartial
    }

    public var title: String { LedgerDates.monthTitle(month) }

    /// `"+AED 16,298.90"`, `"−AED 5,341.48"`, `"AED 0.00"`.
    public var netText: String? { net.map(CashFlow.signed) }

    /// A partial month's net is card spend with no income beside it: not a loss, so not red.
    public var netTone: Tone {
        guard let net, !isPartial else { return .neutral }
        return net > 0 ? .positive : net < 0 ? .warn : .neutral
    }

    /// The month list's figure: `"Partial month"` for a partial one, else the net.
    public var listText: String? { isPartial && net != nil ? CashFlow.partialLabel : netText }

    public var isEmpty: Bool { groups.isEmpty }
}

public enum CashFlow {
    /// Groups `rows` by month, newest month first. A flow with no amount and no transactions is
    /// left out; flows this build doesn't know are dropped (net stays the server's).
    public static func months(_ rows: [CashFlowRow]) -> [CashFlowMonth] {
        let byMonth = Dictionary(grouping: rows, by: \.month)
        return byMonth.keys.sorted(by: >).map { month in
            let monthRows = byMonth[month] ?? []
            let byFlow = Dictionary(monthRows.map { ($0.flow, $0) }, uniquingKeysWith: { a, _ in a })
            let groups = CashFlowGroupKind.allCases.compactMap { kind -> CashFlowGroup? in
                let lines = kind.flows.compactMap { flow -> CashFlowLine? in
                    guard let row = byFlow[flow], row.amountAed != 0 || row.txnCount > 0 else { return nil }
                    return CashFlowLine(flow: flow, amountAed: row.amountAed, txnCount: row.txnCount)
                }
                return lines.isEmpty ? nil : CashFlowGroup(kind: kind, lines: lines)
            }
            return CashFlowMonth(month: month, groups: groups, net: byFlow["net"]?.amountAed,
                                 isPartial: monthRows.contains(where: \.isPartial))
        }
    }

    /// A partial month's chip and list figure.
    public static let partialLabel = "Partial month"

    /// Under a partial month's net.
    public static let partialNote =
        "Your bank activity starts after this month began, so it has card spending but no income: its net isn't a loss."

    /// The month's flows, or an empty month when the server returned none for it.
    public static func month(_ month: CalendarDay, in months: [CashFlowMonth]) -> CashFlowMonth {
        months.first { $0.month == month.startOfMonth }
            ?? CashFlowMonth(month: month.startOfMonth, groups: [], net: nil)
    }

    /// The months the screen offers: the last `count` months up to `today`'s, newest first.
    public static func monthChoices(today: CalendarDay = LedgerDates.today(), count: Int = 6) -> [CalendarDay] {
        (0..<count).map { today.startOfMonth.adding(months: -$0) }
    }

    /// `"+AED 1,200.00"` / `"−AED 1,200.00"` (a true minus sign) / `"AED 0.00"`.
    public static func signed(_ value: Decimal) -> String {
        if value > 0 { return "+" + MoneyFormat.aed(value) }
        if value < 0 { return "−" + MoneyFormat.aed(-value) }
        return MoneyFormat.aed(value)
    }

    /// The empty month: `"No money moved in October yet."` / `"No money moved in September 2026."`.
    public static func emptyMessage(_ month: CalendarDay, today: CalendarDay = LedgerDates.today()) -> String {
        month.startOfMonth == today.startOfMonth
            ? "No money moved in \(LedgerDates.monthName(month)) yet."
            : "No money moved in \(LedgerDates.monthTitle(month))."
    }
}

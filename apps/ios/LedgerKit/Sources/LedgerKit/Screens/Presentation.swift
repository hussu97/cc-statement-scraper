import Foundation

/// Every list and chart has loading, empty and failed states (CLAUDE.md §4.3).
public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?)
    case loaded(Value)
    case failed(String, previous: Value?)

    public var value: Value? {
        switch self {
        case .idle: nil
        case .loading(let v): v
        case .loaded(let v): v
        case .failed(_, let v): v
        }
    }

    public var isLoading: Bool { if case .loading = self { true } else { false } }
    public var errorMessage: String? { if case .failed(let m, _) = self { m } else { nil } }

    func startLoading() -> LoadState { .loading(previous: value) }
    func fail(_ error: any Error) -> LoadState { .failed(Self.message(for: error), previous: value) }

    static func message(for error: any Error) -> String {
        (error as? LedgerAPIError)?.description ?? error.localizedDescription
    }
}

/// Semantic tone; the app maps it to `Palette` colours.
public enum Tone: String, Sendable { case neutral, positive, warn, danger, info }

/// Words for the Overview hero, from numbers the server computed.
public enum SpendComparison {
    /// `"18% below your 3-month average"`.
    public static func versusAverage(spend: Decimal, average: Decimal) -> (text: String, tone: Tone) {
        guard average > 0 else { return ("No 3-month history yet", .neutral) }
        let ratio = (spend - average) / average
        let pct = MoneyFormat.percent(ratio < 0 ? -ratio : ratio)
        if pct == "0%" { return ("In line with your 3-month average", .neutral) }
        return ratio < 0
            ? ("\(pct) below your 3-month average", .positive)
            : ("\(pct) above your 3-month average", .warn)
    }

    /// `"AED 1,200 more than this time last month"`.
    public static func versusLastMonthToDate(spend: Decimal, previous: Decimal) -> String {
        let delta = spend - previous
        if delta == 0 { return "Same as this time last month" }
        let amount = MoneyFormat.aed(delta < 0 ? -delta : delta, fractionDigits: 0)
        return delta < 0 ? "\(amount) less than this time last month" : "\(amount) more than this time last month"
    }
}

/// One card account as the Overview shows it.
public struct AccountSummary: Sendable, Hashable, Identifiable {
    public var id: String { account.accountCode }
    public let account: Overview.OverviewAccount
    /// The server's `closing_balance / credit_limit` from `statement_cycles`.
    public let utilisation: Decimal?

    public init(account: Overview.OverviewAccount, cycles: [StatementCycle]) {
        self.account = account
        let stmt = account.latestStatement?.stmtCode
        utilisation = cycles.first { $0.stmtCode == stmt }?.utilisation
    }

    public func dueLabel(today: CalendarDay = LedgerDates.today()) -> String? {
        guard let due = account.latestStatement?.dueDate else { return nil }
        return LedgerDates.dueLabel(due, today: today)
    }

    public func dueTone(today: CalendarDay = LedgerDates.today()) -> Tone {
        guard let due = account.latestStatement?.dueDate else { return .neutral }
        let days = today.days(until: due)
        return days < 0 ? .danger : days <= 5 ? .warn : .neutral
    }

    public var utilisationLabel: String? { utilisation.map { "\(MoneyFormat.percent($0)) used" } }

    public var utilisationTone: Tone {
        guard let u = utilisation else { return .neutral }
        return u >= Decimal(string: "0.7")! ? .danger : u >= Decimal(string: "0.3")! ? .warn : .positive
    }

    /// Clamped to 0…1 for drawing a bar.
    public var utilisationFraction: Double {
        min(max((utilisation ?? 0).chartValue, 0), 1)
    }
}

/// A reconciliation chip on a statement row.
public struct ReconChip: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public let label: String
    public let tone: Tone

    public static func chips(for cycle: StatementCycle) -> [ReconChip] {
        var chips: [ReconChip] = []
        switch cycle.reconStatus {
        case "ok": chips.append(.init(label: "Reconciled", tone: .positive))
        case "warn": chips.append(.init(label: "Check", tone: .warn))
        case "fail": chips.append(.init(label: "Mismatch", tone: .danger))
        default: chips.append(.init(label: "Not reconciled", tone: .neutral))
        }
        guard let checks = cycle.reconChecks else { return chips }
        if checks.debitsMatch == false { chips.append(.init(label: "Debits differ", tone: .danger)) }
        if checks.creditsMatch == false { chips.append(.init(label: "Credits differ", tone: .danger)) }
        if checks.balanceEquation == false { chips.append(.init(label: "Balance off", tone: .danger)) }
        if checks.totals == "not_extracted" { chips.append(.init(label: "No totals", tone: .warn)) }
        if let n = checks.unmatchedSms, n > 0 {
            chips.append(.init(label: "\(n) SMS not on statement", tone: .warn))
        }
        if let held = checks.heldLines, held > 0 { chips.append(.init(label: "\(held) in review", tone: .warn)) }
        if let coverage = checks.smsCoverage {
            chips.append(.init(label: "SMS \(MoneyFormat.percent(coverage))", tone: .info))
        }
        return chips
    }
}

extension Insight {
    public var tone: Tone {
        switch severity {
        case "alert": .danger
        case "warn": .warn
        default: .info
        }
    }
}

extension DocumentRecord {
    public var tone: Tone {
        switch parseStatus {
        case "parsed": .positive
        case "failed": .danger
        default: .info
        }
    }
}

extension BudgetStatus {
    public var tone: Tone { isOver ? .danger : isProjectedOver ? .warn : .positive }
    public var progressFraction: Double { min(max(shareUsed.chartValue, 0), 1) }
    /// `"AED 1,200 of AED 2,000"`.
    public var progressLabel: String {
        "\(MoneyFormat.aed(spentAed, fractionDigits: 0)) of \(MoneyFormat.aed(budgetAed, fractionDigits: 0))"
    }
}

extension EvidenceBadge {
    public var tone: Tone {
        switch self {
        case .pending: .warn
        case .sms: .info
        case .statement, .void: .neutral
        case .both: .positive
        case .orphaned: .danger
        }
    }
}

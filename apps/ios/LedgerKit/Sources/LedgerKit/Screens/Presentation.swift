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
        if let api = error as? LedgerAPIError {
            if case .server(_, let code, _) = api, code?.hasPrefix("PGRST") == true, !api.isPermission {
                return "Ledger couldn't load this (\(code!)). Pull to refresh, or update the app."
            }
            return api.description
        }
        return error.localizedDescription
    }
}

/// Semantic tone; the app maps it to `Palette` colours.
public enum Tone: String, Sendable { case neutral, positive, warn, danger, info }

/// Words for the Overview hero. Every ratio is the server's
/// (`overview.change_vs_*`); the client only words it (CLAUDE.md §2.2).
public enum SpendComparison {
    /// The month-to-date comparison against the same day last month:
    /// `"18% below the same day last month"`. `change` is the server's
    /// `change_vs_prev_month_to_date`; nil when last month had no spend by then.
    public static func versusSameDayLastMonth(change: Decimal?, spend: Decimal, previous: Decimal) -> (text: String, tone: Tone)? {
        guard let change else {
            return spend > 0 && previous == 0 ? ("Nothing spent by this day last month", .neutral) : nil
        }
        let pct = MoneyFormat.percent(change < 0 ? -change : change)
        if pct == "0%" { return ("Level with the same day last month", .neutral) }
        return change < 0
            ? ("\(pct) below the same day last month", .positive)
            : ("\(pct) above the same day last month", .warn)
    }

    /// A completed month against the 3-month average (`change_vs_avg_3m`).
    /// Not used for the current month: the average is of *whole* months, so a
    /// month-to-date figure would always look far below it.
    public static func versusAverage(change: Decimal?) -> (text: String, tone: Tone)? {
        guard let change else { return nil }
        let pct = MoneyFormat.percent(change < 0 ? -change : change)
        if pct == "0%" { return ("In line with your 3-month average", .neutral) }
        return change < 0
            ? ("\(pct) below your 3-month average", .positive)
            : ("\(pct) above your 3-month average", .warn)
    }
}

/// Due-date wording shared by Overview and Statements. Whether a statement was
/// paid is not known on the phone yet, so a past due date is "Was due …"
/// unless the caller *knows* no payment arrived for the latest statement.
public enum DueStatus {
    /// - Parameters:
    ///   - isLatest: the account's newest statement. An older one was
    ///     superseded by a newer statement, so it is never overdue.
    ///   - paymentDetected: nil when payment detection isn't available —
    ///     then a past due date is never called overdue.
    public static func describe(due: CalendarDay?, isLatest: Bool, paymentDetected: Bool? = nil,
                                today: CalendarDay = LedgerDates.today()) -> (text: String, tone: Tone)? {
        guard let due else { return nil }
        let days = today.days(until: due)
        if days >= 0 {
            return (LedgerDates.dueLabel(due, today: today), days <= 5 ? .warn : .neutral)
        }
        if isLatest, paymentDetected == false {
            return (LedgerDates.dueLabel(due, today: today), .danger)
        }
        return ("Was due \(LedgerDates.dayLabel(due, today: today))", .neutral)
    }
}

/// One card account as the Overview shows it.
public struct AccountSummary: Sendable, Hashable, Identifiable {
    public var id: String { account.accountCode }
    public let account: Overview.OverviewAccount

    public init(account: Overview.OverviewAccount) {
        self.account = account
    }

    /// The server's `accounts[].utilisation` (latest statement balance / limit).
    public var utilisation: Decimal? { account.utilisation }

    /// The latest statement's due date, worded by `DueStatus`.
    public func due(today: CalendarDay = LedgerDates.today()) -> (text: String, tone: Tone)? {
        DueStatus.describe(due: account.latestStatement?.dueDate, isLatest: true, today: today)
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
        let status = ReconPresentation.status(cycle.reconStatus)
        var chips: [ReconChip] = [.init(label: status.label, tone: status.tone)]
        guard let checks = cycle.reconChecks else { return chips }
        if checks.debitsMatch == false { chips.append(.init(label: "Debits differ", tone: .danger)) }
        if checks.creditsMatch == false { chips.append(.init(label: "Credits differ", tone: .danger)) }
        if checks.balanceEquation == false { chips.append(.init(label: "Balance off", tone: .danger)) }
        if checks.totals == "not_extracted" { chips.append(.init(label: "No totals", tone: .warn)) }
        if checks.noLines == true { chips.append(.init(label: "No lines read", tone: .warn)) }
        if let n = checks.unpricedLines, n > 0 { chips.append(.init(label: "\(n) awaiting FX", tone: .info)) }
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

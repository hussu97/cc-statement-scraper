import Foundation

/// Compare accounts (PAR-13, the web's Cards → `AccountComparison`, MA-2): per card account, its
/// statement balance and utilisation over its last 12 statements (`statement_cycles`) and its
/// spending over the last 12 months (`spend_series` by account). Every figure is the server's;
/// this only groups and orders rows for the sparklines (`apps/web/src/data/account-trends.ts`).
public enum AccountComparison {
    /// Statements per account in the balance and utilisation sparklines.
    public static let statements = 12
    /// Months of spend per account.
    public static let months = 12
    /// `statement_cycles` rows fetched, newest first: a year of statements for 30 accounts.
    public static let cycleHistoryLimit = 360

    public static let footnote = "Balance and utilisation are from each account's last \(statements) statements; "
        + "spending covers the last \(months) months."

    /// The spend window: the last `months` whole months, this one included, to today.
    public static func range(today: CalendarDay = LedgerDates.today(), months: Int = months) -> (from: CalendarDay, to: CalendarDay) {
        (today.startOfMonth.adding(months: -(months - 1)), today)
    }

    /// Month starts from `from`'s month to `to`'s month, oldest first.
    public static func monthStarts(from: CalendarDay, to: CalendarDay) -> [CalendarDay] {
        var out: [CalendarDay] = []
        var m = from.startOfMonth
        while m <= to && out.count < 240 {
            out.append(m)
            m = m.adding(months: 1)
        }
        return out
    }

    public struct StatementPoint: Sendable, Hashable {
        public let stmtCode: String
        public let statementDate: CalendarDay
        public let closingBalance: Decimal?
        public let utilisation: Decimal?
        public let creditLimit: Decimal?
    }

    /// Per account, its newest `perAccount` card statements, oldest first (sparkline order).
    /// History extracts are not monthly statements and are left out.
    public static func statementTrends(_ cycles: [StatementCycle], perAccount: Int = statements) -> [String: [StatementPoint]] {
        var out: [String: [StatementPoint]] = [:]
        let newestFirst = cycles.filter { $0.kind == "statement" }.sorted { $0.statementDate > $1.statementDate }
        for c in newestFirst where out[c.accountCode, default: []].count < perAccount {
            out[c.accountCode, default: []].append(StatementPoint(stmtCode: c.stmtCode, statementDate: c.statementDate,
                                                                  closingBalance: c.closingBalance,
                                                                  utilisation: c.utilisation, creditLimit: c.creditLimit))
        }
        return out.mapValues { Array($0.reversed()) }
    }

    public struct MonthPoint: Sendable, Hashable {
        public let month: CalendarDay
        /// The server's amount; 0 when it returned no row for the month (nothing spent).
        public let amount: Decimal
    }

    /// Per account, one point per month of `months`, from `spend_series` grouped by account. An
    /// account with no row in any month is absent (the server found no spending on it).
    public static func monthlySpend(_ rows: [SpendPoint], months: [CalendarDay]) -> [String: [MonthPoint]] {
        var byAccount: [String: [CalendarDay: Decimal]] = [:]
        for row in rows {
            guard let account = row.groupKey else { continue }
            byAccount[account, default: [:]][row.bucket.startOfMonth] = row.amount
        }
        return byAccount.mapValues { amounts in months.map { MonthPoint(month: $0, amount: amounts[$0] ?? 0) } }
    }

    /// One figure of an account's row: label, the latest server value, a caption and its sparkline.
    public struct Cell: Sendable, Hashable {
        public let label: String
        public let value: String
        public let caption: String
        public let spark: Sparkline?
        /// What VoiceOver reads for the whole cell, sparkline included.
        public let accessibilityLabel: String
    }

    /// The statement balance cell; nil points read "No statements yet".
    public static func balanceCell(_ points: [StatementPoint]) -> Cell {
        guard let latest = points.last, let first = points.first else {
            return Cell(label: "Balance", value: "—", caption: "No statements yet", spark: nil,
                        accessibilityLabel: "Statement balance: no statements yet")
        }
        let value = aed(latest.closingBalance)
        let spoken = between(points, first: first, latest: latest) { aed($0.closingBalance) }
        return Cell(label: "Balance", value: value, caption: span(points),
                    spark: Sparkline(points.map(\.closingBalance)),
                    accessibilityLabel: "Statement balance \(value). \(spoken)")
    }

    /// Utilisation of the credit limit, 0–100%; "—" when no statement knows the limit.
    public static func utilisationCell(_ points: [StatementPoint]) -> Cell {
        guard let latest = points.last, let first = points.first else {
            return Cell(label: "Utilisation", value: "—", caption: "No statements yet", spark: nil,
                        accessibilityLabel: "Utilisation: no statements yet")
        }
        guard points.contains(where: { $0.utilisation != nil }) else {
            return Cell(label: "Utilisation", value: "—", caption: "No credit limit known", spark: nil,
                        accessibilityLabel: "Utilisation: no credit limit known")
        }
        let value = percent(latest.utilisation)
        let caption = latest.creditLimit.map { "of \(MoneyFormat.aed($0))" } ?? "of the limit"
        let spoken = between(points, first: first, latest: latest) { percent($0.utilisation) }
        return Cell(label: "Utilisation", value: value, caption: caption,
                    spark: Sparkline(points.map(\.utilisation), min: 0, max: 1),
                    accessibilityLabel: "Utilisation of the credit limit \(value), \(caption). \(spoken)")
    }

    /// Monthly spending; nil points (no row in any month) read as nothing spent.
    public static func spendingCell(_ points: [MonthPoint]?, months: Int = months) -> Cell {
        guard let points, let latest = points.last, let first = points.first else {
            return Cell(label: "Spending", value: MoneyFormat.aed(0), caption: "None in \(months) months", spark: nil,
                        accessibilityLabel: "Spending: none in \(months) months")
        }
        let value = MoneyFormat.aed(latest.amount)
        let caption = "\(LedgerDates.monthAbbrev(latest.month)) so far"
        return Cell(label: "Spending", value: value, caption: caption,
                    spark: Sparkline(points.map { Optional($0.amount) }, min: 0),
                    accessibilityLabel: "Monthly spending, \(MoneyFormat.aed(first.amount)) in \(LedgerDates.monthName(first.month)) "
                        + "to \(value) in \(LedgerDates.monthName(latest.month)) so far, over \(points.count) months")
    }

    static func aed(_ v: Decimal?) -> String { v.map { MoneyFormat.aed($0) } ?? "—" }
    static func percent(_ v: Decimal?) -> String { v.map { MoneyFormat.percent($0) } ?? "—" }

    /// `"25 Sep statement"` for one, `"12 statements"` for more.
    static func span(_ points: [StatementPoint]) -> String {
        guard points.count != 1, !points.isEmpty else {
            return points.first.map { "\(LedgerDates.dayLabel($0.statementDate)) statement" } ?? ""
        }
        return "\(points.count) statements"
    }

    static func between(_ points: [StatementPoint], first: StatementPoint, latest: StatementPoint,
                        _ pick: (StatementPoint) -> String) -> String {
        points.count == 1
            ? "\(pick(latest)) on \(LedgerDates.fullDayLabel(latest.statementDate))"
            : "\(pick(first)) on \(LedgerDates.fullDayLabel(first.statementDate)) to \(pick(latest)) on \(LedgerDates.fullDayLabel(latest.statementDate))"
    }
}

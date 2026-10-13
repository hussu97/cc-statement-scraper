import Foundation
import Observation

/// The Statements screen's "Compare accounts" card (PAR-13). Three reads, each with its own
/// state so a failed one shows its own error: the accounts, their statement history and their
/// monthly spend. Every member may read them.
@MainActor
@Observable
public final class AccountComparisonModel {
    public struct Row: Sendable, Identifiable {
        public var id: String { account.accountCode }
        public let account: LedgerAccount
        /// The web's colour by rank (`rankToken`): the same account keeps its colour across cells.
        public let colorToken: String
    }

    public private(set) var accounts: LoadState<[LedgerAccount]> = .idle
    public private(set) var statements: LoadState<[String: [AccountComparison.StatementPoint]]> = .idle
    public private(set) var spending: LoadState<[String: [AccountComparison.MonthPoint]]> = .idle
    /// The months the spending cells cover, oldest first.
    public private(set) var months: [CalendarDay] = []

    private let api: any LedgerAPI
    private var gate = RequestGate<String>()

    public init(api: any LedgerAPI) {
        self.api = api
    }

    /// The card shows only when there are accounts: the cycles list already says when there are
    /// none or that it failed (the web hides it the same way).
    public var isVisible: Bool {
        if case .failed = accounts, accounts.value == nil { return false }
        return accounts.value.map { !$0.isEmpty } ?? true
    }

    public var rows: [Row] {
        let listed: [LedgerAccount] = accounts.value ?? []
        let tokens = ChartPalette.categoryTokens
        return listed.enumerated().map { i, account in
            Row(account: account, colorToken: tokens[i % tokens.count])
        }
    }

    public func balanceCell(_ row: Row) -> AccountComparison.Cell {
        AccountComparison.balanceCell(statements.value?[row.account.accountCode] ?? [])
    }

    public func utilisationCell(_ row: Row) -> AccountComparison.Cell {
        AccountComparison.utilisationCell(statements.value?[row.account.accountCode] ?? [])
    }

    public func spendingCell(_ row: Row) -> AccountComparison.Cell {
        AccountComparison.spendingCell(spending.value?[row.account.accountCode], months: months.count)
    }

    public func load(profileCode: String, today: CalendarDay = LedgerDates.today()) async {
        let (ticket, same) = gate.begin(profileCode)
        if !same {
            accounts = .idle
            statements = .idle
            spending = .idle
        }
        accounts = accounts.startLoading()
        statements = statements.startLoading()
        spending = spending.startLoading()
        let range = AccountComparison.range(today: today)
        let months = AccountComparison.monthStarts(from: range.from, to: range.to)
        let api = self.api
        async let a = Self.result { try await api.accounts(profileCode: profileCode) }
        async let c = Self.result { try await api.statementCycles(profileCode: profileCode, limit: AccountComparison.cycleHistoryLimit) }
        async let s = Self.result {
            try await api.spendSeries(profileCode: profileCode, from: range.from, to: range.to, grain: .month, group: .account)
        }
        let (accountRows, cycles, series) = await (a, c, s)
        guard gate.isCurrent(ticket) else { return }
        self.months = months
        accounts = Self.state(accountRows, previous: accounts.value)
        statements = Self.state(cycles.map { AccountComparison.statementTrends($0) }, previous: statements.value)
        spending = Self.state(series.map { AccountComparison.monthlySpend($0, months: months) }, previous: spending.value)
        gate.finish(profileCode)
    }

    public func reset() {
        gate.reset()
        accounts = .idle
        statements = .idle
        spending = .idle
        months = []
    }

    nonisolated static func result<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    static func state<T>(_ result: Result<T, any Error>, previous: T?) -> LoadState<T> {
        switch result {
        case .success(let value): .loaded(value)
        case .failure(let error): .failed(LoadState<T>.message(for: error), previous: previous)
        }
    }
}

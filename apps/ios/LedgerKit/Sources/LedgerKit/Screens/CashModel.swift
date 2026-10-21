import Foundation
import Observation

/// Wealth mode's Accounts and Cash flow tabs: the bank accounts with their balances
/// (`cash_position`) and the last months' cash flow (`cash_flow`, the whole ledger or one
/// account), plus Update balance and Add bank account for owners. Every figure is the server's;
/// the model only groups and words them.
@MainActor
@Observable
public final class CashModel {
    public struct Content: Sendable {
        public let position: CashPosition
        /// The months' flows, newest first; empty when they failed (`flowError`).
        public let months: [CashFlowMonth]
        /// Cash flow failed to load: the accounts still show.
        public let flowError: String?
        /// Saving by holding (`cash_flow_savings`), for the same accounts; empty when it failed.
        public let savings: [SavingByHolding]

        public init(position: CashPosition, months: [CashFlowMonth], flowError: String? = nil,
                    savings: [SavingByHolding] = []) {
            self.position = position
            self.months = months
            self.flowError = flowError
            self.savings = savings
        }
    }

    public struct Notice: Equatable, Sendable {
        public let text: String
        public let isError: Bool
    }

    public private(set) var state: LoadState<Content> = .idle
    /// The month whose flows are shown (first of the month).
    public var selectedMonth: CalendarDay
    /// The Cash flow tab's account; nil is every account.
    public private(set) var accountFilter: String?
    public private(set) var isSaving = false
    /// The last write's outcome, shown above the accounts.
    public var notice: Notice?
    /// Runs after a successful write, with the ledger: Wealth's Overview reloads.
    @ObservationIgnored public var onChange: (@MainActor (String) async -> Void)?

    private let api: any LedgerAPI
    private let today: @Sendable () -> CalendarDay
    private var gate = RequestGate<String>()

    public init(api: any LedgerAPI, today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() }) {
        self.api = api
        self.today = today
        selectedMonth = today().startOfMonth
    }

    /// The months the screen offers, newest first.
    public var monthChoices: [CalendarDay] { CashFlow.monthChoices(today: today()) }

    /// The selected month's flows (an empty month when nothing moved).
    public var selected: CashFlowMonth? {
        state.value.map { CashFlow.month(selectedMonth, in: $0.months) }
    }

    /// The month list under the groups: each offered month with the server's net, if any.
    public var monthNets: [CashFlowMonth] {
        guard let months = state.value?.months else { return [] }
        return monthChoices.map { CashFlow.month($0, in: months) }
    }

    public func emptyMessage(for month: CalendarDay) -> String { CashFlow.emptyMessage(month, today: today()) }

    /// The selected month's saving by holding, Unassigned last; empty when there is no split to show
    /// (nothing linked, or it failed).
    public var selectedSavings: [SavingLine] {
        let lines = CashFlowSavings.lines(state.value?.savings ?? [], month: selectedMonth)
        return CashFlowSavings.showsBreakdown(lines) ? lines : []
    }

    /// The account filter's choices: the bank accounts (cards' flows are their spend, under every account).
    public var accountChoices: [BankAccountBalance] { state.value?.position.accounts ?? [] }

    /// `"All accounts"`, or the filtered account's name.
    public var accountFilterLabel: String {
        guard let accountFilter else { return "All accounts" }
        return accountChoices.first { $0.accountCode == accountFilter }?.title ?? "One account"
    }

    /// Shows one account's flows (nil: every account) and reloads them.
    public func setAccountFilter(_ code: String?, profileCode: String) async {
        guard code != accountFilter else { return }
        accountFilter = code
        await load(profileCode: profileCode)
    }

    public func load(profileCode: String) async {
        let (ticket, sameKey) = gate.begin(profileCode)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        let choices = monthChoices
        let from = choices.last ?? today().startOfMonth
        let to = today().endOfMonth
        let api = self.api
        let account = accountFilter
        do {
            async let position = api.cashPosition(profileCode: profileCode)
            // Saving by holding is extra: failing, it leaves the split out.
            async let savings = try? api.cashFlowSavings(profileCode: profileCode, from: from, to: to, accountCode: account)
            async let flow: Result<[CashFlowRow], any Error> = {
                do {
                    return .success(try await api.cashFlow(profileCode: profileCode, from: from, to: to, accountCode: account))
                } catch {
                    return .failure(error)
                }
            }()
            let (p, f, sv) = try await (position, flow, savings)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(profileCode)
            switch f {
            case .success(let rows):
                state = .loaded(Content(position: p, months: CashFlow.months(rows), savings: sv ?? []))
            case .failure(let error):
                state = .loaded(Content(position: p, months: [], flowError: LoadState<Content>.message(for: error)))
            }
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    /// Loads unless this ledger is already on screen or loading.
    public func loadIfNeeded(profileCode: String) async {
        guard gate.requested != profileCode || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode)
    }

    /// Reloads what is on screen (foreground, Realtime, after a write), if anything is.
    public func refresh(profileCode: String) async {
        guard gate.requested == profileCode else { return }
        await load(profileCode: profileCode)
    }

    public func reset() {
        gate.reset()
        state = .idle
        notice = nil
        isSaving = false
        selectedMonth = today().startOfMonth
        accountFilter = nil
    }

    // MARK: Writes (owners)

    /// Validates and records the balance. Nil when saved (the sheet closes), else the sentence the form shows.
    public func updateBalance(_ draft: UpdateBalanceDraft, profileCode: String) async -> String? {
        if let problem = draft.validate() { return problem }
        return await write(profileCode: profileCode, saved: UpdateBalanceDraft.savedMessage) {
            try await $0.recordBalance(profileCode: profileCode, accountCode: draft.accountCode,
                                       balance: draft.normalizedAmount)
        } failure: { UpdateBalanceDraft.message(for: $0) }
    }

    /// Validates and adds the account. Nil when added, else the sentence the form shows.
    public func addAccount(_ draft: AddBankAccountDraft, profileCode: String) async -> String? {
        if let problem = draft.validate() { return problem }
        guard let bank = draft.bankCode else { return nil }
        return await write(profileCode: profileCode, saved: draft.savedMessage) {
            _ = try await $0.createBankAccount(profileCode: profileCode, bankCode: bank, kind: draft.kind,
                                               accountRef: draft.normalizedRef, nickname: draft.normalizedNickname)
        } failure: { draft.message(for: $0) }
    }

    private func write(profileCode: String, saved: String, _ call: (any LedgerAPI) async throws -> Void,
                       failure: (any Error) -> String) async -> String? {
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            try await call(api)
        } catch {
            return failure(error)
        }
        notice = Notice(text: saved, isError: false)
        await refresh(profileCode: profileCode)
        await onChange?(profileCode)
        return nil
    }
}

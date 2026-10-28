import Foundation
import Observation

/// One holding's screen: its flows (with the payment that paid each) and recorded values
/// (`holding_detail`), its returns for every period (`holding_returns`), and the owner's Add money
/// in / out / income, Remove or Unlink a flow, and Update value. The summary is the Investments
/// tab's row for it, so a write here refreshes that tab (`onChange`). Every figure is the server's.
@MainActor
@Observable
public final class HoldingDetailModel {
    public let holdingCode: String
    public private(set) var detail: LoadState<HoldingDetail> = .idle
    /// This holding's row in each period's returns; nil inside a loaded state when the server sent none.
    public private(set) var returns: [ReturnsPeriod: LoadState<HoldingReturn?>] = [:]
    public private(set) var isSaving = false
    /// The last write's outcome, shown at the top.
    public var notice: InvestmentsModel.Notice?

    private let api: any LedgerAPI
    private let today: @Sendable () -> CalendarDay
    private let onChange: @MainActor (String) async -> Void

    public init(holdingCode: String, api: any LedgerAPI,
                today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() },
                onChange: @escaping @MainActor (String) async -> Void = { _ in }) {
        self.holdingCode = holdingCode
        self.api = api
        self.today = today
        self.onChange = onChange
    }

    public func load(profileCode: String) async {
        detail = detail.startLoading()
        for period in ReturnsPeriod.holding { returns[period] = .loading(previous: returns[period]?.value) }
        let api = self.api
        let code = holdingCode
        async let d: Result<HoldingDetail, any Error> = Self.result { try await api.holdingDetail(profileCode: profileCode, holdingCode: code) }
        async let all: Result<HoldingReturns, any Error> = Self.result { try await api.holdingReturns(profileCode: profileCode, period: .all) }
        async let ytd: Result<HoldingReturns, any Error> = Self.result { try await api.holdingReturns(profileCode: profileCode, period: .ytd) }
        async let year: Result<HoldingReturns, any Error> = Self.result {
            try await api.holdingReturns(profileCode: profileCode, period: .twelveMonths)
        }
        let (dr, a, y, t) = await (d, all, ytd, year)
        switch dr {
        case .success(let value): detail = .loaded(value)
        case .failure(let error): detail = detail.fail(error)
        }
        for (period, result) in [(ReturnsPeriod.all, a), (.ytd, y), (.twelveMonths, t)] {
            switch result {
            case .success(let r): returns[period] = .loaded(r.figures(for: code))
            case .failure(let error): returns[period] = .failed(LoadState<Int>.message(for: error), previous: nil)
            }
        }
    }

    /// Loads unless already loaded or loading.
    public func loadIfNeeded(profileCode: String) async {
        guard detail.value == nil, !detail.isLoading else { return }
        await load(profileCode: profileCode)
    }

    private static func result<T: Sendable>(_ call: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await call()) } catch { return .failure(error) }
    }

    // MARK: What the screen shows

    /// This holding's figures for `period`; nil while loading, failed or not sent.
    public func figures(for period: ReturnsPeriod) -> ReturnFigures? { returns[period]?.value??.figures }

    /// Newest first, as the server sends them.
    public var flows: [HoldingFlow] { detail.value?.flows ?? [] }
    public var valuations: [HoldingValuationRecord] { detail.value?.valuations ?? [] }

    /// The flows' empty state, said only once loaded.
    public func noFlowsMessage(for holding: Holding) -> String? {
        guard detail.value != nil, flows.isEmpty else { return nil }
        if holding.kind == .metal { return "Add what you paid on the holding to count its gain." }
        if holding.isSavingsAccount {
            return "No transfers or interest on the account yet. They're added as its transactions arrive."
        }
        guard let match = holding.linkRuleMatch else {
            return "No money in or out yet. Add it here, or link the payments from their transactions."
        }
        return "No money in or out yet. Payments \(match) are linked as they arrive."
    }

    /// Under the flows: where a savings account's come from; nil for other kinds.
    public func flowsNote(for holding: Holding) -> String? {
        guard holding.isSavingsAccount else { return nil }
        return "The account's transfers in and out and its interest, from its statements and SMS. Change them on the account's transactions."
    }

    /// Whether the screen lists values: the kinds you value yourself, and a deposit once its
    /// bank's statement has valued it.
    public func showsValueHistory(for holding: Holding) -> Bool {
        holding.canRecordValue || (holding.kind == .deposit && !valuations.isEmpty)
    }

    /// The value history's empty state.
    public func noValuesMessage(for holding: Holding) -> String? {
        guard holding.canRecordValue, detail.value != nil, valuations.isEmpty else { return nil }
        return holding.kind == .security ? "No price recorded yet." : "No value recorded yet."
    }

    // MARK: Writes (owners)

    public func newFlow(for holding: Holding) -> FlowDraft { FlowDraft(holding: holding, today: today()) }
    public func newValue(for holding: Holding) -> ValueDraft { ValueDraft(holding: holding, today: today()) }

    /// Validates and records a flow. Nil when saved (the sheet closes), else the sentence the form shows.
    public func addFlow(_ draft: FlowDraft, profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return HoldingDraft.ownerOnlyMessage }
        if let problem = draft.validate(today: today()) { return problem }
        guard let submission = draft.submission(today: today()) else { return nil }
        return await write(profileCode: profileCode, saved: draft.savedMessage) {
            try await $0.addHoldingFlow(profileCode: profileCode, flow: submission)
        }
    }

    /// Removes a flow added by hand, or unlinks a payment (its rule won't link it again).
    public func remove(_ flow: HoldingFlow, profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return HoldingDraft.ownerOnlyMessage }
        guard flow.canRemove else { return "A metal's cost is changed on the holding: Edit it." }
        return await write(profileCode: profileCode, saved: flow.removedMessage) {
            if let txn = flow.txnCode {
                try await $0.linkTransaction(profileCode: profileCode, txnCode: txn, holdingCode: nil)
            } else {
                try await $0.removeHoldingFlow(profileCode: profileCode, flowCode: flow.flowCode)
            }
        }
    }

    /// Validates and records a value or unit price. Nil when saved, else the sentence the form shows.
    public func recordValue(_ draft: ValueDraft, profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return HoldingDraft.ownerOnlyMessage }
        if let problem = draft.validate(today: today()) { return problem }
        guard let submission = draft.submission(today: today()) else { return nil }
        return await write(profileCode: profileCode, saved: draft.savedMessage) {
            try await $0.recordHoldingValue(profileCode: profileCode, value: submission)
        }
    }

    private func write(profileCode: String, saved: String,
                       _ call: (any LedgerAPI) async throws -> Void) async -> String? {
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            try await call(api)
        } catch {
            return HoldingDraft.message(for: error)
        }
        notice = InvestmentsModel.Notice(text: saved, isError: false)
        await load(profileCode: profileCode)
        await onChange(profileCode)
        return nil
    }
}

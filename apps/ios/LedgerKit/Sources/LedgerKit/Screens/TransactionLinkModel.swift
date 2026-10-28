import Foundation
import Observation

/// The transaction sheet's "Link to investment" (owners): which holding a payment went to, the
/// holdings to choose from, and Link / Unlink (`link_transaction`). A linked payment is saving,
/// not spending; an unlinked one is never linked again by the holding's rule. The screen that
/// opened the sheet saves it (`TransactionEditing.saveLink`) and re-reads what changed.
@MainActor
@Observable
public final class TransactionLinkModel {
    public let transaction: LedgerTransaction
    /// The holding it is linked to now: the row's, then whatever was last saved here.
    public private(set) var linkedCode: String?
    public private(set) var linkedName: String?
    /// The active holdings, as Investments lists them.
    public private(set) var choices: LoadState<[Holding]> = .idle
    public private(set) var isSaving = false
    public var errorMessage: String?

    private let api: any LedgerAPI
    private let profileCode: String
    private let target: any TransactionEditing

    public init(transaction: LedgerTransaction, profileCode: String, api: any LedgerAPI, target: any TransactionEditing) {
        self.transaction = transaction
        self.profileCode = profileCode
        self.api = api
        self.target = target
        linkedCode = transaction.holdingCode
        linkedName = transaction.holdingName
    }

    public var isLinked: Bool { linkedCode != nil }

    /// `"RL360 plan"`, or `"Not linked"`.
    public var statusText: String { linkedName ?? "Not linked" }

    /// The server needs an AED amount to count it.
    public var canLink: Bool { transaction.amountAed != nil }
    public static let noAmountMessage = "This transaction has no AED amount yet, so it can't be linked."

    public static let footer =
        "A payment linked to an investment counts as saving, not spending, and adds to what the investment cost. Unlink it and the investment's payment rule won't link it again."

    /// The holdings to choose from, by kind as Investments groups them. A savings account is left
    /// out: its flows are its own account's transactions, never a linked payment.
    public var groups: [HoldingGroup] { HoldingGroup.groups(choices.value ?? [], kinds: HoldingKind.addable) }

    /// The picker's empty state, said only once loaded.
    public var noChoicesMessage: String? {
        guard let holdings = choices.value, holdings.isEmpty else { return nil }
        return "No investments yet. Add one under Wealth → Investments, then link its payments here."
    }

    /// Loads the holdings to choose from, once.
    public func loadChoices() async {
        guard choices.value == nil, !choices.isLoading else { return }
        choices = .loading(previous: nil)
        do {
            choices = .loaded(try await api.holdingsValuation(profileCode: profileCode).holdings)
        } catch {
            choices = choices.fail(error)
        }
    }

    /// Links the payment to `holding`. True when saved.
    public func link(_ holding: Holding) async -> Bool {
        guard holding.holdingCode != linkedCode else { return true }
        guard canLink else {
            errorMessage = Self.noAmountMessage
            return false
        }
        return await save(holding.holdingCode, name: holding.name)
    }

    /// Unlinks the payment (for good: the rule leaves it alone). True when saved.
    public func unlink() async -> Bool { await save(nil, name: nil) }

    private func save(_ code: String?, name: String?) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await target.saveLink(transaction, holdingCode: code, profileCode: profileCode)
            linkedCode = code
            linkedName = name
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    /// The server's refusals in plain words.
    public nonisolated static func message(for error: any Error) -> String {
        guard let api = error as? LedgerAPIError, case let .server(_, code, message) = api else {
            return LoadState<Bool>.message(for: error)
        }
        if api.isPermission { return HoldingDraft.ownerOnlyMessage }
        switch code {
        case "22023": return "Couldn't link it: \(message)."
        case "P0002": return "That transaction or investment isn't in the ledger any more. Pull to refresh."
        default: return LoadState<Bool>.message(for: error)
        }
    }
}

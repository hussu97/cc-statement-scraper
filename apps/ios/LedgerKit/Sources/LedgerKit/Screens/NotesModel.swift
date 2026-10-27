import Foundation
import Observation

/// Structured notes on Investments and on the account that pays for them
/// (`structured_notes_summary`), each note's screen (`NoteDetailModel`) and an account's deposits
/// and withdrawals (`add_account_entry`). The Swissquote sync adds notes from their term sheets;
/// a note posts its purchase, coupons and redemptions to its account, so every write tells the
/// screens that show money (`onChange`). Every figure is the server's.
@MainActor
@Observable
public final class NotesModel {
    public private(set) var state: LoadState<[NoteSummary]> = .idle
    public private(set) var isSaving = false
    /// The last write's outcome (a note added or removed, an entry added).
    public var notice: InvestmentsModel.Notice?
    /// Runs after a write, with the ledger: investments, cash, the ledgers and Activity reload.
    @ObservationIgnored public var onChange: (@MainActor (String) async -> Void)?

    private let api: any LedgerAPI
    private let today: @Sendable () -> CalendarDay
    private var gate = RequestGate<String>()

    public init(api: any LedgerAPI, today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() }) {
        self.api = api
        self.today = today
    }

    public func load(profileCode: String) async {
        let (ticket, sameKey) = gate.begin(profileCode)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        do {
            let notes = try await api.structuredNotes(profileCode: profileCode)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(profileCode)
            state = .loaded(notes)
        } catch {
            if gate.isCurrent(ticket) { state = state.fail(error) }
        }
    }

    /// Loads unless this ledger's notes are on screen or loading.
    public func loadIfNeeded(profileCode: String) async {
        guard gate.requested != profileCode || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode)
    }

    /// Re-reads what is on screen, if anything is (Realtime, the foreground, another tab's write).
    public func refresh(profileCode: String) async {
        guard gate.requested == profileCode else { return }
        await load(profileCode: profileCode)
    }

    public func reset() {
        gate.reset()
        state = .idle
        notice = nil
        isSaving = false
    }

    // MARK: What the screens show

    /// The live notes to list (never an ended one): those paid from `fundingAccount` (all when
    /// nil), leaving out the holdings a synced broker account shows (`excluding`). Nil until loaded.
    public func liveRows(fundingAccount: String? = nil, excluding: Set<String> = []) -> [NoteListRow]? {
        state.value.map { NoteListRow.rows($0, fundingAccount: fundingAccount, excluding: excluding, today: today()) }
    }

    /// The note behind a holding, once loaded.
    public func note(holdingCode: String) -> NoteSummary? { state.value?.first { $0.holdingCode == holdingCode } }

    // MARK: Screens

    /// A note's screen. Its writes (Update prices, Remove) refresh this list and the money screens.
    public func detailModel(for holdingCode: String) -> NoteDetailModel {
        NoteDetailModel(holdingCode: holdingCode, api: api) { [weak self] code, notice in
            if let notice { self?.notice = notice }
            await self?.afterWrite(profileCode: code)
        }
    }

    // MARK: Account entries (owners)

    public func newEntry(for account: BankAccountBalance) -> AccountEntryDraft { AccountEntryDraft(account: account, today: today()) }

    /// Validates and records a deposit or withdrawal. Nil when saved (the sheet closes), else the sentence the form shows.
    public func addEntry(_ draft: AccountEntryDraft, profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return NoteFlowText.ownerOnly }
        if let problem = draft.validate(today: today()) { return problem }
        guard let submission = draft.submission(today: today()), !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await api.addAccountEntry(profileCode: profileCode, entry: submission)
        } catch {
            return NoteFlowText.message(for: error)
        }
        notice = InvestmentsModel.Notice(text: draft.savedMessage, isError: false)
        await afterWrite(profileCode: profileCode)
        return nil
    }

    func afterWrite(profileCode: String) async {
        await refresh(profileCode: profileCode)
        await onChange?(profileCode)
    }
}

/// The sentences the notes' writes show.
public enum NoteFlowText {
    public static let ownerOnly = "Only the ledger's owners can change its notes."

    public static func message(for error: any Error) -> String {
        guard let api = error as? LedgerAPIError, case let .server(_, code, message) = api else {
            return LoadState<Bool>.message(for: error)
        }
        if api.isPermission { return ownerOnly }
        switch code {
        case "22023", "23514", "UNREADABLE": return "Check the note: \(message)."
        case "P0002": return "This note or account isn't in the ledger any more. Pull to refresh."
        default: return LoadState<Bool>.message(for: error)
        }
    }
}

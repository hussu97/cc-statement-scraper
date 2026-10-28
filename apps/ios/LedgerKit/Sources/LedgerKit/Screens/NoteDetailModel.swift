import Foundation
import Observation

/// One structured note's screen (`structured_note_detail`): where it stands, what comes next, the
/// shares against the barriers, what it can pay and its schedule, with the owner's Update prices
/// (`stock-prices`) and Remove (`cancel_structured_note`). Every figure is the server's.
@MainActor
@Observable
public final class NoteDetailModel {
    public let holdingCode: String
    public private(set) var state: LoadState<NoteDetail> = .idle
    public private(set) var isSaving = false
    /// Update prices' outcome, shown at the top.
    public var notice: InvestmentsModel.Notice?
    /// The term sheet viewer (signed URL, bytes in memory while it is open).
    public let termSheet: TermSheetPDF

    private let api: any LedgerAPI
    /// After a write: the ledger and, for the list, a notice to show there.
    private let onChange: @MainActor (String, InvestmentsModel.Notice?) async -> Void

    public init(holdingCode: String, api: any LedgerAPI,
                onChange: @escaping @MainActor (String, InvestmentsModel.Notice?) async -> Void = { _, _ in },
                fetchPDF: @escaping StatementPDF.Fetch = StatementPDF.download) {
        self.holdingCode = holdingCode
        self.api = api
        termSheet = TermSheetPDF(api: api, fetch: fetchPDF)
        self.onChange = onChange
    }

    public func load(profileCode: String) async {
        state = state.startLoading()
        do {
            state = .loaded(try await api.structuredNoteDetail(profileCode: profileCode, holdingCode: holdingCode))
        } catch {
            state = state.fail(error)
        }
    }

    /// Opens the loaded note's term sheet, titled by the note.
    public func openTermSheet() async {
        guard let note = state.value else { return }
        await termSheet.open(path: note.terms.termsheetPath, filename: note.terms.termsheetFilename,
                             title: note.summary.name)
    }

    public func loadIfNeeded(profileCode: String) async {
        guard state.value == nil, !state.isLoading else { return }
        await load(profileCode: profileCode)
    }

    // MARK: What the screen offers

    /// Update prices: owners, while the note is live. Not a credit-linked note: it has no shares.
    public func canRefreshPrices(canEdit: Bool) -> Bool {
        canEdit && state.value.map { !$0.isEnded && !$0.summary.isCreditLinked } == true
    }

    /// Remove: owners, unless it is already cancelled.
    public func canRemove(canEdit: Bool) -> Bool {
        canEdit && state.value.map { $0.summary.noteStatus != .cancelled } == true
    }

    public static let removeTitle = "Remove this note?"
    public static let removeMessage =
        "For a note added by mistake. Its purchase, coupons and redemptions leave the account's ledger; the terms are kept."

    // MARK: Writes (owners)

    /// Fetches the closes the ledger's notes need and settles them, then re-reads the note.
    public func refreshPrices(profileCode: String, canEdit: Bool) async {
        guard canEdit else {
            notice = .init(text: NoteFlowText.ownerOnly, isError: true)
            return
        }
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await api.refreshNotePrices(profileCode: profileCode)
            notice = .init(text: result.message, isError: false)
        } catch {
            notice = .init(text: "Couldn't update prices. \(NoteFlowText.message(for: error))", isError: true)
            return
        }
        await load(profileCode: profileCode)
        await onChange(profileCode, nil)
    }

    /// Cancels the note. Nil when removed (the screen goes back), else why not.
    public func remove(profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return NoteFlowText.ownerOnly }
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.cancelStructuredNote(profileCode: profileCode, holdingCode: holdingCode)
        } catch {
            return NoteFlowText.message(for: error)
        }
        let name = state.value?.summary.name ?? "The note"
        await onChange(profileCode, .init(text: "\(name) removed.", isError: false))
        return nil
    }
}

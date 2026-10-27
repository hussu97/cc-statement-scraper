import Foundation
import Observation

/// Adding a structured note from its term sheet: pick the PDF, `termsheet-extract` reads it (about
/// half a minute), the owner reviews the name and the price symbols and says what was bought and
/// from which account, then `create_structured_note` saves it and `stock-prices` fetches the closes
/// its past observations need. Per-cell edits of the schedule are left to the web app.
@MainActor
@Observable
public final class AddNoteModel {
    public enum Phase: Equatable, Sendable { case choosing, extracting, review }

    public private(set) var phase: Phase = .choosing
    /// The reviewed draft; the name and symbols are edited in place.
    public var draft: NoteDraft?
    public private(set) var warnings: [String] = []
    public var form: NoteDraftForm
    /// The last failure (reading, loading accounts, saving), shown in the sheet.
    public private(set) var error: String?
    public private(set) var isSaving = false
    /// The bank accounts in the ledger, from `cash_position`; filtered to the note's currency.
    public private(set) var accounts: [BankAccountBalance] = []
    /// After a save: what to tell the owner (prices fetched, or why not).
    public private(set) var savedMessage: String?

    private let api: any LedgerAPI
    private let today: @Sendable () -> CalendarDay
    private let presetAccount: String?
    /// After a save: the ledger and what to tell the owner.
    private let onChange: @MainActor (String, String?) async -> Void

    public init(api: any LedgerAPI, today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() },
                fundingAccount: String? = nil, onChange: @escaping @MainActor (String, String?) async -> Void = { _, _ in }) {
        self.api = api
        self.today = today
        presetAccount = fundingAccount
        self.onChange = onChange
        form = NoteDraftForm(tradeDate: today(), fundingAccountCode: fundingAccount)
    }

    public static let title = "Add a structured note"
    public static let chooseHint = "The issuer's final terms (PDF): underlyings and initial levels, the observation schedule, and what is paid at maturity. Nothing is saved until you confirm."
    public static let extractingHint = "Claude is transcribing the coupons, autocall dates and payout. This takes about half a minute."
    public static let symbolHint = "The price symbol is the ticker the daily closes come from (Yahoo Finance): AMZN, NESN.SW."
    public static let scheduleFooter = "To correct a date or level, use the web app."

    // MARK: Reading the term sheet

    /// Sends the PDF to `termsheet-extract`; on success the review opens with what was read.
    public func extract(_ file: UploadFile, profileCode: String, canEdit: Bool) async {
        guard canEdit else {
            error = NoteFlowText.ownerOnly
            return
        }
        guard phase != .extracting else { return }
        error = nil
        phase = .extracting
        do {
            let result = try await api.extractTermSheet(profileCode: profileCode, file: file)
            draft = result.draft
            warnings = result.warnings
            form = NoteDraftForm(tradeDate: result.draft.defaultTradeDate ?? today(), fundingAccountCode: presetAccount)
            phase = .review
            await loadAccounts(profileCode: profileCode)
        } catch {
            self.error = NoteFlowText.message(for: error)
            phase = .choosing
        }
    }

    /// Reads the picked PDF (off the main thread: an iCloud Drive file may download first), then extracts it.
    public func extract(url: URL, profileCode: String, canEdit: Bool) async {
        let file = await StatementsModel.offMain { try? StatementsModel.readFile(url) }
        guard let file else {
            error = "Couldn't read \(url.lastPathComponent)."
            return
        }
        await extract(file, profileCode: profileCode, canEdit: canEdit)
    }

    /// The ledger's bank accounts in the note's currency; one alone is picked for the owner.
    func loadAccounts(profileCode: String) async {
        do {
            let all = try await api.cashPosition(profileCode: profileCode).accounts
            let currency = draft?.terms.currency.uppercased() ?? ""
            accounts = all.filter { $0.currency.uppercased() == currency }
            if form.fundingAccountCode == nil || !accounts.contains(where: { $0.accountCode == form.fundingAccountCode }) {
                form.fundingAccountCode = accounts.count == 1 ? accounts[0].accountCode : nil
            }
        } catch {
            accounts = []
            form.fundingAccountCode = nil
        }
    }

    // MARK: The review

    /// Under the account picker.
    public var accountHint: String {
        let currency = draft?.terms.currency.uppercased() ?? ""
        return accounts.isEmpty
            ? "No \(currency) bank account yet: add your Swissquote account under Accounts to track its cash. The note is saved without one."
            : "Coupons and redemptions are paid back into it on their payment dates."
    }

    /// The price field's placeholder: the issue price.
    public var pricePlaceholder: String { draft?.terms.issuePricePct ?? "" }

    public var amountLabel: String { "Amount invested (\(draft?.terms.currency.uppercased() ?? "—"))" }

    public func setName(_ name: String) { draft?.name = name }

    public func setSymbol(_ index: Int, _ symbol: String) {
        guard let count = draft?.terms.underlyings.count, index < count else { return }
        draft?.terms.underlyings[index].symbol = symbol.uppercased()
    }

    /// Validates and saves, then fetches prices. The holding code when saved (the sheet opens the
    /// note), else nil with `error` set.
    public func save(profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else {
            error = NoteFlowText.ownerOnly
            return nil
        }
        guard let draft, !isSaving else { return nil }
        let problems = form.problems(draft)
        guard problems.isEmpty else {
            error = problems.joined(separator: " ")
            return nil
        }
        error = nil
        isSaving = true
        defer { isSaving = false }
        let code: String
        do {
            code = try await api.createStructuredNote(profileCode: profileCode, draft: form, reviewed: draft)
        } catch {
            self.error = NoteFlowText.message(for: error)
            return nil
        }
        // The note is saved; prices follow on the nightly run if this call fails.
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        do {
            let prices = try await api.refreshNotePrices(profileCode: profileCode)
            savedMessage = prices.failed.isEmpty
                ? "\(name) added: prices are in, its status is up to date."
                : "\(name) added. No prices for \(prices.failed.joined(separator: ", ")) yet: check the symbols."
        } catch {
            savedMessage = "\(name) added. Prices will follow on tonight's run."
        }
        await onChange(profileCode, savedMessage)
        return code
    }
}

/// One add flow per sheet.
extension AddNoteModel: Identifiable {}

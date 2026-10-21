import Foundation
import Observation

/// One user-field write to `public.transactions` (CLAUDE.md §1.10: only
/// `manual_category_code`, `notes` and `exclude_from_spend` are edited directly;
/// the category goes through `set_transaction_category`).
public enum TransactionEdit: Sendable, Hashable {
    case excludeFromSpend(Bool)
    /// Nil clears the note.
    case notes(String?)
}

/// A screen that lists transactions and can save an owner's edits to one,
/// re-reading what changed (Activity patches rows in place; a statement reloads).
/// Throws the API's error so the sheet that asked can show it.
@MainActor
public protocol TransactionEditing: AnyObject {
    func saveCategory(_ txn: LedgerTransaction, to categoryCode: String?, applyToMerchant: Bool,
                      profileCode: String) async throws
    func saveEdit(_ txn: LedgerTransaction, _ edit: TransactionEdit, profileCode: String) async throws
    /// Links the payment to a holding, or unlinks it (nil) for good (`link_transaction`).
    func saveLink(_ txn: LedgerTransaction, holdingCode: String?, profileCode: String) async throws
}

/// The transaction sheet (IOS-18): category with search and "None", the
/// merchant-wide toggle, exclude from spend, and notes. Owners only; the
/// screens never open it for a viewer.
@MainActor
@Observable
public final class TransactionEditor {
    /// What is being saved; every control waits for it.
    public enum Busy: Sendable, Hashable {
        /// Nil is "None".
        case category(String?)
        case exclude
        case notes
    }

    public nonisolated static let notesLimit = 1000

    public let transaction: LedgerTransaction
    public let categories: [FilterMeta.CategoryOption]
    public var search = ""
    /// Starts on unless the category is the transaction's own manual choice
    /// (`defaultsToMerchant`).
    public var applyToMerchant: Bool
    public var notesDraft: String
    public private(set) var excluded: Bool
    public private(set) var savedNotes: String?
    public private(set) var busy: Busy?
    public var errorMessage: String?

    private let profileCode: String
    private let target: any TransactionEditing

    public init(transaction: LedgerTransaction, categories: [FilterMeta.CategoryOption], profileCode: String,
                target: any TransactionEditing) {
        self.transaction = transaction
        self.categories = categories
        self.profileCode = profileCode
        self.target = target
        applyToMerchant = Self.defaultsToMerchant(transaction)
        excluded = transaction.excludeFromSpend
        let notes = Self.normalizedNotes(transaction.notes ?? "")
        savedNotes = notes
        notesDraft = notes ?? ""
    }

    // MARK: What the sheet shows

    public var showsMerchantToggle: Bool { transaction.merchantCode != nil }
    public var merchantToggleTitle: String { "Apply to every \(transaction.title) transaction" }
    /// "Category · Your choice": where the current category came from.
    public var categoryHeader: String {
        Self.sourceLabel(transaction.categorySource).map { "Category · \($0)" } ?? "Category"
    }
    public var visibleCategories: [FilterMeta.CategoryOption] { Self.filter(categories, search: search) }
    /// Exclude and notes hide while searching, so the matches sit at the top.
    public var showsDetails: Bool { Self.needle(search).isEmpty }
    public var showsNone: Bool {
        let needle = Self.needle(search)
        return needle.isEmpty || "none".localizedStandardContains(needle)
    }
    public var noneSelected: Bool { transaction.categoryCode == nil }
    /// "None" clears a manual choice; with nothing manual to clear it would do nothing.
    public var canChooseNone: Bool { Self.canClear(source: transaction.categorySource, applyToMerchant: willApplyToMerchant) }
    public var noMatchMessage: String? {
        let needle = Self.needle(search)
        guard !needle.isEmpty, visibleCategories.isEmpty, !showsNone else { return nil }
        return "No category matches “\(needle)”."
    }
    public var notesChanged: Bool { Self.normalizedNotes(notesDraft) != savedNotes }

    private var willApplyToMerchant: Bool { showsMerchantToggle && applyToMerchant }

    // MARK: Actions

    /// Saves the category (nil: "None"). True when saved; the sheet then closes.
    public func choose(_ categoryCode: String?) async -> Bool {
        guard busy == nil else { return false }
        if categoryCode == nil && !canChooseNone { return false }
        busy = .category(categoryCode)
        defer { busy = nil }
        do {
            try await target.saveCategory(transaction, to: categoryCode, applyToMerchant: willApplyToMerchant,
                                          profileCode: profileCode)
            return true
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
            return false
        }
    }

    /// Saves at once (the switch shows the new value, and goes back if it fails).
    public func setExcluded(_ value: Bool) async {
        guard busy == nil, value != excluded else { return }
        excluded = value
        busy = .exclude
        defer { busy = nil }
        do {
            try await target.saveEdit(transaction, .excludeFromSpend(value), profileCode: profileCode)
        } catch {
            excluded = !value
            errorMessage = LoadState<Int>.message(for: error)
        }
    }

    public func saveNotes() async {
        guard busy == nil, notesChanged else { return }
        let notes = Self.normalizedNotes(notesDraft)
        busy = .notes
        defer { busy = nil }
        do {
            try await target.saveEdit(transaction, .notes(notes), profileCode: profileCode)
            savedNotes = notes
            notesDraft = notes ?? ""
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
        }
    }

    public func discardNotes() { notesDraft = savedNotes ?? "" }

    // MARK: Pure

    /// Applying to the merchant is the common intent and stops the next
    /// transaction from that merchant arriving uncategorised, so it starts on,
    /// except when this transaction carries its own manual choice (a deliberate
    /// one-off, which a merchant-wide default would undo).
    public nonisolated static func defaultsToMerchant(_ txn: LedgerTransaction) -> Bool {
        txn.merchantCode != nil && txn.categorySource != "manual"
    }

    /// `set_transaction_category(null)` clears the transaction's manual choice
    /// and, merchant-wide, the merchant's: "None" is live only when one exists.
    public nonisolated static func canClear(source: String?, applyToMerchant: Bool) -> Bool {
        source == "manual" || (applyToMerchant && source == "merchant")
    }

    /// The web drawer's words for `v_transactions.category_source`.
    public nonisolated static func sourceLabel(_ source: String?) -> String? {
        switch source {
        case "manual": "Your choice"
        case "merchant": "Your choice for this merchant"
        case "rule": "Set by a rule"
        case "suggested": "Suggested"
        default: nil
        }
    }

    /// Categories whose name contains the search (case and accents ignored), in server order.
    public nonisolated static func filter(_ categories: [FilterMeta.CategoryOption],
                                          search: String) -> [FilterMeta.CategoryOption] {
        let needle = needle(search)
        guard !needle.isEmpty else { return categories }
        return categories.filter { $0.name.localizedStandardContains(needle) }
    }

    /// Trimmed, at most `notesLimit` characters; blank is no note.
    public nonisolated static func normalizedNotes(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(notesLimit))
    }

    /// The swipe action that flips `exclude_from_spend`.
    public nonisolated static func excludeActionTitle(excluded: Bool) -> String {
        excluded ? "Include" : "Exclude"
    }

    nonisolated static func needle(_ search: String) -> String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

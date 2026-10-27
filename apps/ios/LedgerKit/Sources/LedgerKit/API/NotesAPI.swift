import Foundation

/// Structured notes (`20261027124257_structured_notes.sql`; the Swissquote sync creates them from
/// their term sheets) and the price refresh (`stock-prices`), plus typed account entries. Part of `LedgerAPI`;
/// implemented in `SupabaseLedgerAPI+Notes.swift`. Every figure is the server's.
public protocol NotesAPI: Sendable {
    /// `rpc('structured_notes_summary')`: every note of the ledger (cancelled ones left out), live
    /// first, newest trade first (members).
    func structuredNotes(profileCode: String) async throws -> [NoteSummary]
    /// `rpc('structured_note_detail')`: one note in full (members; P0002 when unknown).
    func structuredNoteDetail(profileCode: String, holdingCode: String) async throws -> NoteDetail
    /// `rpc('cancel_structured_note')`: for a note added by mistake; its ledger entries are voided,
    /// the terms kept (owners).
    func cancelStructuredNote(profileCode: String, holdingCode: String) async throws
    /// `POST functions/v1/stock-prices`: the closes the ledger's notes need, then settlement (owners).
    func refreshNotePrices(profileCode: String) async throws -> NotePriceRefresh
    /// `rpc('add_account_entry')`: a deposit or withdrawal on a bank account; returns the entry code (owners).
    func addAccountEntry(profileCode: String, entry: AccountEntryDraft.Submission) async throws -> String
}

/// What `stock-prices` did: how many symbols it priced, closes stored, notes settled, and the
/// symbols it found no price for.
public struct NotePriceRefresh: Decodable, Sendable, Hashable {
    public let symbols: Int
    public let stored: Int
    public let settled: Int?
    public let failed: [String]

    public init(symbols: Int = 0, stored: Int, settled: Int? = nil, failed: [String] = []) {
        self.symbols = symbols
        self.stored = stored
        self.settled = settled
        self.failed = failed
    }

    /// The notice after Update prices: `"Prices updated: 12 closes stored."`.
    public var message: String {
        failed.isEmpty
            ? "Prices updated: \(stored == 1 ? "1 close" : "\(stored) closes") stored."
            : "Prices updated. No prices for: \(failed.joined(separator: ", "))."
    }
}

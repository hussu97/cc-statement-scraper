import Foundation
import Supabase

/// Structured notes and account entries (`20261027124257_structured_notes.sql`); the price
/// refresh is an Edge Function (`NoteFunctions`).
extension SupabaseLedgerAPI {
    public func structuredNotes(profileCode: String) async throws -> [NoteSummary] {
        try await rpc("structured_notes_summary", [NoteSummary].self, ["p_profile_code": .string(profileCode)])
    }

    public func structuredNoteDetail(profileCode: String, holdingCode: String) async throws -> NoteDetail {
        try await rpc("structured_note_detail", NoteDetail.self, [
            "p_profile_code": .string(profileCode), "p_holding_code": .string(holdingCode),
        ])
    }

    public func cancelStructuredNote(profileCode: String, holdingCode: String) async throws {
        _ = try await read(Ignored.self) {
            try await client.rpc("cancel_structured_note", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_holding_code": .string(holdingCode),
            ]).execute()
        }
    }

    public func refreshNotePrices(profileCode: String) async throws -> NotePriceRefresh {
        try await noteFunctions.refreshPrices(profileCode: profileCode, accessToken: try await accessToken())
    }

    public func addAccountEntry(profileCode: String, entry e: AccountEntryDraft.Submission) async throws -> String {
        try await rpc("add_account_entry", String.self, [
            "p_profile_code": .string(profileCode), "p_account_code": .string(e.accountCode),
            "p_direction": .string(e.direction.rawValue), "p_amount": .string(e.amount),
            "p_entry_date": .string(e.entryDate.iso), "p_description": e.description.map(AnyJSON.string) ?? .null,
        ])
    }

    private var noteFunctions: NoteFunctions {
        NoteFunctions(functionsURL: config.functionsURL, apiKey: config.supabasePublishableKey, session: session)
    }
}

import Foundation
import Supabase

/// Activity's bulk actions (PAR-11): the selection's figures and the bulk write, exactly as the
/// web's bulk bar calls them (`apps/web/src/data/transactions.ts`).
extension SupabaseLedgerAPI {
    public func activitySelectionSummary(profileCode: String,
                                         selection: ActivityBulkSelection) async throws -> ActivitySelectionSummary {
        try await rpc("activity_selection_summary", ActivitySelectionSummary.self, selection.params(profileCode: profileCode))
    }

    public func bulkUpdateTransactions(profileCode: String, patch: ActivityBulkPatch,
                                       selection: ActivityBulkSelection) async throws -> Int {
        try await rpc("bulk_update_transactions", Int.self, selection.bulkUpdateParams(profileCode: profileCode, patch: patch))
    }
}

extension ActivityBulkSelection {
    /// `bulk_update_transactions`' arguments: the selection and the patch.
    public func bulkUpdateParams(profileCode: String, patch: ActivityBulkPatch) -> [String: AnyJSON] {
        var out = params(profileCode: profileCode)
        out["p_patch"] = patch.json
        return out
    }
}

import Foundation
import Supabase

/// `public.budgets`, written the way the web writes it (apps/web/src/data/budgets.ts):
/// owners only (RLS `budgets_owner_write`), the amount as a decimal string.
extension SupabaseLedgerAPI {
    public func budgets(profileCode: String) async throws -> [Budget] {
        try await read([Budget].self) {
            try await client.from("budgets")
                .select("budget_code,category_code,amount_aed,effective_from,effective_to")
                .eq("profile_code", value: profileCode)
                .order("effective_from", ascending: false)
                .execute()
        }
    }

    public func saveBudget(profileCode: String, draft: BudgetDraft) async throws {
        var row: [String: AnyJSON] = [
            "category_code": draft.categoryCode.map(AnyJSON.string) ?? .null,
            // numeric(14,2): PostgREST takes the decimal string as-is, no float on the way.
            "amount_aed": .string(draft.normalizedAmount),
            "effective_from": .string(draft.effectiveFrom.iso),
            "effective_to": draft.effectiveTo.json,
        ]
        if let code = draft.budgetCode {
            _ = try await read(Ignored.self) {
                try await client.from("budgets").update(row).eq("budget_code", value: code).execute()
            }
        } else {
            row["profile_code"] = .string(profileCode)
            _ = try await read(Ignored.self) { try await client.from("budgets").insert(row).execute() }
        }
    }

    public func deleteBudget(budgetCode: String) async throws {
        _ = try await read(Ignored.self) {
            try await client.from("budgets").delete().eq("budget_code", value: budgetCode).execute()
        }
    }
}

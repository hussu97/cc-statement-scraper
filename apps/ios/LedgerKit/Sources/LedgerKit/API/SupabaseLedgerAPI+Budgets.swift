import Foundation
import Supabase

/// `public.budgets`, written the way the web writes it (apps/web/src/data/budgets.ts):
/// owners only (RLS `budgets_owner_write`), the amount as a decimal string.
/// Budgets are read through `budget_status` (with `p_include_inactive`), never
/// from the table: which one counts is the server's call (WEB-28i).
extension SupabaseLedgerAPI {
    public func saveBudget(profileCode: String, draft: BudgetDraft) async throws {
        var row: [String: AnyJSON] = [
            "account_code": draft.accountCode.map(AnyJSON.string) ?? .null,
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

    public func accounts(profileCode: String) async throws -> [LedgerAccount] {
        try await read([LedgerAccount].self) {
            try await client.from("accounts")
                .select("account_code,bank_code,nickname,product_name,status")
                .eq("profile_code", value: profileCode)
                .order("bank_code")
                .execute()
        }
    }

    public func deleteBudget(budgetCode: String) async throws {
        _ = try await read(Ignored.self) {
            try await client.from("budgets").delete().eq("budget_code", value: budgetCode).execute()
        }
    }
}

import Foundation
import Supabase

/// Bank accounts, balances and cash flow (Phase 2d), as the web reads and writes them. Every
/// figure is the server's; a balance goes up as the decimal string the person typed.
extension SupabaseLedgerAPI {
    public func cashPosition(profileCode: String) async throws -> CashPosition {
        try await rpc("cash_position", CashPosition.self, ["p_profile_code": .string(profileCode)])
    }

    public func cashFlow(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [CashFlowRow] {
        try await rpc("cash_flow", [CashFlowRow].self,
                      ["p_profile_code": .string(profileCode), "p_from": .string(from.iso), "p_to": .string(to.iso)])
    }

    public func recordBalance(profileCode: String, accountCode: String, balance: String) async throws {
        _ = try await read(Ignored.self) {
            try await client.rpc("record_balance", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_account_code": .string(accountCode),
                "p_balance": .string(balance),
            ]).execute()
        }
    }

    public func createBankAccount(profileCode: String, bankCode: String, kind: BankAccountKind, accountRef: String,
                                  nickname: String?) async throws -> String {
        try await rpc("create_bank_account", String.self, [
            "p_profile_code": .string(profileCode), "p_bank_code": .string(bankCode), "p_kind": .string(kind.rawValue),
            "p_account_ref": .string(accountRef), "p_nickname": nickname.map(AnyJSON.string) ?? .null,
        ])
    }
}

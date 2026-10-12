import Foundation
import Supabase

/// Card payments from the "Log Card Payment" App Intent, and the card names
/// they are matched by (`cards.wallet_name`, owner-editable by column grant).
extension SupabaseLedgerAPI {
    public func ingestWalletPayments(profileCode: String, items: [WalletPayment]) async throws -> [SMSIngestResult] {
        try await rpc("ingest_wallet_transactions", [SMSIngestResult].self, [
            "p_profile_code": .string(profileCode),
            "p_items": .array(items.map(\.json)),
        ])
    }

    public func cards(profileCode: String) async throws -> [LedgerCard] {
        try await read([LedgerCard].self) {
            try await client.from("cards")
                .select("card_code,account_code,bank_code,last4,status,wallet_name")
                .eq("profile_code", value: profileCode)
                .order("bank_code")
                .order("last4")
                .execute()
        }
    }

    public func updateCardWalletName(cardCode: String, name: String?) async throws {
        _ = try await read(Ignored.self) {
            try await client.from("cards")
                .update(["wallet_name": name.map(AnyJSON.string) ?? .null])
                .eq("card_code", value: cardCode)
                .execute()
        }
    }
}

import Foundation
import Supabase

/// What the transaction sheet reads beside the row: the merchant context, the
/// evidence timeline, the SMS text on request, and the reversal pair (PAR-2).
extension SupabaseLedgerAPI {
    public func merchantContext(profileCode: String, merchantCode: String) async throws -> MerchantContext {
        try await rpc("merchant_context", MerchantContext.self,
                      ["p_profile_code": .string(profileCode), "p_merchant_code": .string(merchantCode)])
    }

    public func transactionEvidence(profileCode: String, txnCode: String) async throws -> [EvidenceItem] {
        let rows = try await read([EvidenceItem].self) {
            try await client.from("transaction_evidence").select(EvidenceItem.select)
                .eq("profile_code", value: profileCode)
                .eq("txn_code", value: txnCode)
                .execute()
        }
        return EvidenceItem.sorted(rows)
    }

    public func smsBody(profileCode: String, smsCode: String) async throws -> String? {
        struct Row: Decodable { let body: String? }
        let rows = try await read([Row].self) {
            try await client.from("sms_messages").select("body")
                .eq("profile_code", value: profileCode)
                .eq("sms_code", value: smsCode)
                .limit(1)
                .execute()
        }
        return rows.first?.body
    }

    public func relatedTransactions(profileCode: String, txn: LedgerTransaction) async throws -> [LedgerTransaction] {
        let rows = try await read([LedgerTransaction].self) {
            try await client.from("v_transactions").select("*")
                .eq("profile_code", value: profileCode)
                .or(txn.relatedFilter)
                .limit(10)
                .execute()
        }
        return rows.filter { $0.txnCode != txn.txnCode }
    }
}

extension LedgerTransaction {
    /// PostgREST `or` for the reversal pair: rows that point at this one, and the one it points at.
    var relatedFilter: String {
        var filters = ["related_txn_code.eq.\(txnCode)"]
        if let relatedTxnCode { filters.append("txn_code.eq.\(relatedTxnCode)") }
        return filters.joined(separator: ",")
    }
}

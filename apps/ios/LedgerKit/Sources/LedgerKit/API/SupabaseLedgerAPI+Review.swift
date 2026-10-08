import Foundation
import Supabase

extension SupabaseLedgerAPI {
    /// Open reviews, then — in parallel — the SMS (parsed fields only, never
    /// the body), statement lines and candidate transactions they refer to,
    /// and the profile's accounts (for registering an unknown card).
    public func reviewInbox(profileCode: String) async throws -> ReviewInbox {
        let reviews = try await read([MatchReview].self) {
            try await client.from("match_reviews")
                .select("review_code,account_code,subject_type,subject_code,reason,candidates,created_at")
                .eq("profile_code", value: profileCode)
                .eq("status", value: "open")
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
        }
        let smsCodes = reviews.filter { $0.subjectType == "sms" }.map(\.subjectCode)
        let lineCodes = reviews.filter { $0.subjectType == "statement_line" }.map(\.subjectCode)
        let txnCodes = Array(Set(reviews.flatMap { r in
            r.candidates.compactMap(\.txnCode) + (r.subjectType == "transaction" ? [r.subjectCode] : [])
        }))

        async let sms: [ReviewSMS] = smsCodes.isEmpty ? [] : read([ReviewSMS].self) {
            try await client.from("sms_messages")
                .select("sms_code,bank_code,card_last4,amount,currency,merchant_raw,received_at")
                .in("sms_code", values: smsCodes)
                .execute()
        }
        async let lines: [ReviewLine] = lineCodes.isEmpty ? [] : read([ReviewLine].self) {
            try await client.from("statement_lines")
                .select("line_code,txn_date,description,amount_original,currency_original,direction,card_last4")
                .in("line_code", values: lineCodes)
                .execute()
        }
        async let txns: [LedgerTransaction] = txnCodes.isEmpty ? [] : read([LedgerTransaction].self) {
            try await client.from("v_transactions").select("*").in("txn_code", values: txnCodes).execute()
        }
        async let accounts: [LedgerAccount] = read([LedgerAccount].self) {
            try await client.from("accounts")
                .select("account_code,bank_code,nickname,product_name")
                .eq("profile_code", value: profileCode)
                .eq("status", value: "active")
                .order("bank_code")
                .execute()
        }
        let (s, l, t, a) = try await (sms, lines, txns, accounts)
        return ReviewInbox(
            reviews: reviews,
            sms: Dictionary(s.map { ($0.smsCode, $0) }, uniquingKeysWith: { a, _ in a }),
            lines: Dictionary(l.map { ($0.lineCode, $0) }, uniquingKeysWith: { a, _ in a }),
            transactions: Dictionary(t.map { ($0.txnCode, $0) }, uniquingKeysWith: { a, _ in a }),
            accounts: a)
    }

    public func resolveReview(reviewCode: String, action: ReviewAction) async throws -> String {
        struct Result: Decodable { let outcome: String? }
        let result = try await rpc("resolve_review", Result.self, [
            "p_review_code": .string(reviewCode),
            "p_action": action.json,
        ])
        return result.outcome ?? "done"
    }
}

extension ReviewAction {
    /// `p_action` for `resolve_review`.
    var json: AnyJSON {
        switch self {
        case .link(let txnCode): .object(["link": .string(txnCode)])
        case .createNew: .object(["create_new": .bool(true)])
        case .dismiss: .object(["dismiss": .bool(true)])
        case .registerCard(let accountCode): .object(["card": .object(["account_code": .string(accountCode)])])
        }
    }
}

import Foundation
import Supabase

/// Statement detail, the spend split, banks and the upload timeline.
extension SupabaseLedgerAPI {
    public func statementDetail(profileCode: String, stmtCode: String) async throws -> StatementDetail {
        try await rpc("statement_detail", StatementDetail.self,
                      ["p_profile_code": .string(profileCode), "p_stmt_code": .string(stmtCode)])
    }

    public func spendBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay, groupBy: SpendSplitGrouping,
                               topN: Int) async throws -> SpendBreakdown {
        guard groupBy != .none else {
            throw LedgerAPIError.server(status: nil, code: "22023", message: "Choose category, bank or merchant.")
        }
        let data: Data
        do {
            data = try await client.rpc("spend_breakdown", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_from": .string(from.iso), "p_to": .string(to.iso),
                "p_group_by": .string(groupBy.rawValue), "p_top_n": .integer(topN),
            ]).execute().data
        } catch {
            throw Self.map(error)
        }
        // Not LedgerJSON: its snake-case conversion would rewrite the group keys.
        return try SpendBreakdown.decode(data)
    }

    public func banks() async throws -> [BankInfo] {
        // `*`: `logo_path` arrived with migration 20261010000100; an older
        // server simply has no logos to offer.
        try await read([BankInfo].self) {
            try await client.from("banks").select("*").order("bank_code").execute()
        }
    }

    public func transaction(profileCode: String, txnCode: String) async throws -> LedgerTransaction? {
        try await read([LedgerTransaction].self) {
            try await client.from("v_transactions").select("*")
                .eq("profile_code", value: profileCode).eq("txn_code", value: txnCode)
                .limit(1).execute()
        }.first
    }

    public func documentEvents(profileCode: String, docCodes: [String]) async throws -> [DocumentEvent] {
        guard !docCodes.isEmpty else { return [] }
        return try await read([DocumentEvent].self) {
            try await client.from("document_events")
                .select("event_code,profile_code,doc_code,created_at,stage,level,message,detail")
                .eq("profile_code", value: profileCode)
                .in("doc_code", values: docCodes)
                .order("created_at").order("event_code")
                .limit(500)
                .execute()
        }
    }

    public func documentEventStream(profileCode: String) -> AsyncStream<DocumentEvent> {
        let client = self.client
        return AsyncStream { continuation in
            let task = Task {
                // A topic of its own: the screens' change feed keeps its channel.
                let channel = client.channel("document-events-\(profileCode)-\(UUID().uuidString.prefix(8))")
                let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "document_events",
                                                     filter: .eq("profile_code", value: profileCode))
                do {
                    try await channel.subscribeWithError()
                } catch {
                    continuation.finish()
                    return
                }
                let decoder = LedgerJSON.makeDecoder()
                for await insert in inserts {
                    if let event = try? insert.decodeRecord(as: DocumentEvent.self, decoder: decoder) {
                        continuation.yield(event)
                    }
                }
                await client.removeChannel(channel)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

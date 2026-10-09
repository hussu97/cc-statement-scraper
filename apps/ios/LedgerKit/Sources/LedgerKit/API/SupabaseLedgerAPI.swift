import Foundation
import Supabase

/// `LedgerAPI` over supabase-swift. Responses are taken as raw bytes and decoded
/// with `LedgerJSON`, so money always goes through the exact-decimal path.
public final class SupabaseLedgerAPI: LedgerAPI, @unchecked Sendable {
    public let client: SupabaseClient
    private let config: LedgerConfig
    private let session: URLSession

    public init(client: SupabaseClient, config: LedgerConfig, session: URLSession = .shared) {
        self.client = client
        self.config = config
        self.session = session
    }

    // MARK: Identity

    public func profiles() async throws -> [LedgerProfile] {
        try await read([LedgerProfile].self) {
            try await client.from("profiles").select("profile_code,key,name,base_currency").order("name").execute()
        }
    }

    public func memberships() async throws -> [ProfileMembership] {
        let uid = try await currentUserID()
        return try await read([ProfileMembership].self) {
            try await client.from("profile_members").select("profile_code,role").eq("user_id", value: uid).execute()
        }
    }

    public func createProfile(key: String, name: String) async throws -> String {
        try await read(String.self) {
            try await client.rpc("create_profile", params: ["p_key": AnyJSON.string(key), "p_name": .string(name)]).execute()
        }
    }

    // MARK: Analytics

    public func overview(profileCode: String, month: CalendarDay?) async throws -> Overview {
        try await rpc("overview", Overview.self, ["p_profile_code": .string(profileCode), "p_month": month.json])
    }

    public func categoryBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [CategorySpend] {
        try await rpc("category_breakdown", [CategorySpend].self,
                      ["p_profile_code": .string(profileCode), "p_from": .string(from.iso), "p_to": .string(to.iso)])
    }

    public func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain, group: SpendGroup,
                            filter: SpendFilter) async throws -> [SpendPoint] {
        let params: [String: AnyJSON] = [
            "p_profile_code": .string(profileCode), "p_from": .string(from.iso), "p_to": .string(to.iso),
            "p_grain": .string(grain.rawValue), "p_group": .string(group.rawValue),
        ]
        return try await rpc("spend_series", [SpendPoint].self, params.merging(filter.rpcParams) { a, _ in a })
    }

    public func merchantLeaderboard(profileCode: String, from: CalendarDay, to: CalendarDay, limit: Int) async throws -> [MerchantSpend] {
        try await rpc("merchant_leaderboard", [MerchantSpend].self, [
            "p_profile_code": .string(profileCode), "p_from": .string(from.iso), "p_to": .string(to.iso),
            "p_limit": .integer(limit),
        ])
    }

    public func statementCycles(profileCode: String, limit: Int) async throws -> [StatementCycle] {
        try await rpc("statement_cycles", [StatementCycle].self, ["p_profile_code": .string(profileCode), "p_limit": .integer(limit)])
    }

    public func budgetStatus(profileCode: String, month: CalendarDay?) async throws -> [BudgetStatus] {
        try await rpc("budget_status", [BudgetStatus].self, ["p_profile_code": .string(profileCode), "p_month": month.json])
    }

    public func recurringList(profileCode: String) async throws -> [RecurringCharge] {
        try await rpc("recurring_list", [RecurringCharge].self, ["p_profile_code": .string(profileCode)])
    }

    public func filterMeta(profileCode: String) async throws -> FilterMeta {
        try await rpc("filter_meta", FilterMeta.self, ["p_profile_code": .string(profileCode)])
    }

    public func activitySummary(profileCode: String, query: ActivityQuery) async throws -> ActivitySummary {
        try await rpc("activity_summary", ActivitySummary.self, query.summaryParams(profileCode: profileCode))
    }

    // MARK: Tables

    public func transactions(profileCode: String, query: ActivityQuery, page: PageRequest) async throws -> TransactionPage {
        do {
            var q = client.from("v_transactions").select("*", count: .exact).eq("profile_code", value: profileCode)
            if let search = query.searchOrFilter { q = q.or(search) }
            if let account = query.accountCode { q = q.eq("account_code", value: account) }
            if query.uncategorizedOnly {
                q = q.is("category_code", value: nil)
            } else if let category = query.categoryCode {
                q = q.eq("category_code", value: category)
            }
            if query.status != .all { q = q.eq("status", value: query.status.rawValue) }
            if let from = query.from { q = q.gte("txn_date", value: from.iso) }
            if let to = query.to { q = q.lte("txn_date", value: to.iso) }
            let response = try await q
                .order("txn_date", ascending: false)
                .order("txn_at", ascending: false, nullsFirst: false)
                .order("txn_code", ascending: false)
                .range(from: page.offset, to: page.lastIndex)
                .execute()
            let rows = try LedgerJSON.decode([LedgerTransaction].self, from: response.data)
            return TransactionPage(rows: rows, total: response.count)
        } catch {
            throw Self.map(error)
        }
    }

    public func transactions(profileCode: String, codes: [String]) async throws -> [LedgerTransaction] {
        // 100 codes per request keeps the `in.(…)` filter well inside URL limits.
        var out: [LedgerTransaction] = []
        for start in stride(from: 0, to: codes.count, by: 100) {
            let chunk = Array(codes[start..<min(start + 100, codes.count)])
            out += try await read([LedgerTransaction].self) {
                try await client.from("v_transactions").select("*")
                    .eq("profile_code", value: profileCode)
                    .in("txn_code", values: chunk)
                    .execute()
            }
        }
        return out
    }

    public func insights(profileCode: String) async throws -> [Insight] {
        try await read([Insight].self) {
            try await client.from("insights")
                .select("insight_code,kind,severity,title,body,valid_until,dismissed_at,created_at")
                .eq("profile_code", value: profileCode)
                .is("dismissed_at", value: nil)
                .order("created_at", ascending: false)
                .limit(20)
                .execute()
        }
    }

    public func dismissInsight(insightCode: String) async throws {
        _ = try await read(Ignored.self) {
            try await client.from("insights")
                .update(["dismissed_at": AnyJSON.string(LedgerDates.isoTimestamp(.now))])
                .eq("insight_code", value: insightCode)
                .execute()
        }
    }

    public func documents(profileCode: String, page: PageRequest) async throws -> ListPage<DocumentRecord> {
        do {
            let response = try await client.from("documents")
                .select("doc_code,kind,bank_code,original_filename,source,parse_status,parse_error_code,parse_error,created_at,parsed_at",
                        count: .exact)
                .eq("profile_code", value: profileCode)
                .order("created_at", ascending: false)
                .order("doc_code", ascending: false)
                .range(from: page.offset, to: page.lastIndex)
                .execute()
            return ListPage(items: try LedgerJSON.decode([DocumentRecord].self, from: response.data), total: response.count)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Writes

    public func setTransactionCategory(txnCode: String, categoryCode: String, applyToMerchant: Bool) async throws {
        _ = try await read(Ignored.self) {
            try await client.rpc("set_transaction_category", params: [
                "p_txn_code": AnyJSON.string(txnCode), "p_category_code": .string(categoryCode),
                "p_apply_to_merchant": .bool(applyToMerchant),
            ]).execute()
        }
    }

    public func ingestSMS(profileCode: String, messages: [SMSPayload]) async throws -> [SMSIngestResult] {
        try await rpc("ingest_sms", [SMSIngestResult].self, [
            "p_profile_code": .string(profileCode),
            "p_messages": .array(messages.map(\.json)),
        ])
    }

    public func uploadStatements(profileCode: String, files: [UploadFile]) async throws -> UploadResponse {
        let token = try await accessToken()
        let uploader = StatementUploader(functionsURL: config.functionsURL, apiKey: config.supabasePublishableKey, session: session)
        return try await uploader.upload(files: files, profileCode: profileCode, accessToken: token)
    }

    // MARK: Realtime

    public func changes(profileCode: String) -> AsyncStream<LedgerChange> {
        let client = self.client
        return AsyncStream { continuation in
            let task = Task {
                let channel = client.channel("ledger-\(profileCode)")
                let tables = ["transactions", "sms_messages", "documents", "insights"]
                let streams = tables.map { table in
                    (table, channel.postgresChange(AnyAction.self, schema: "public", table: table,
                                                   filter: .eq("profile_code", value: profileCode)))
                }
                do {
                    try await channel.subscribeWithError()
                } catch {
                    // `client.channel` returns an existing channel by topic: remove
                    // the failed one so `LiveUpdates`' retry builds a fresh one.
                    await client.removeChannel(channel)
                    continuation.finish()
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    for (table, stream) in streams {
                        group.addTask {
                            for await _ in stream { continuation.yield(LedgerChange(table: table)) }
                        }
                    }
                }
                await client.removeChannel(channel)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Plumbing

    struct Ignored: Decodable {}

    private func currentUserID() async throws -> String {
        do { return try await client.auth.session.user.id.uuidString.lowercased() } catch { throw LedgerAPIError.notSignedIn }
    }

    func accessToken() async throws -> String {
        do { return try await client.auth.session.accessToken } catch { throw LedgerAPIError.notSignedIn }
    }

    func rpc<T: Decodable>(_ name: String, _ type: T.Type, _ params: [String: AnyJSON]) async throws -> T {
        try await read(type) { try await client.rpc(name, params: params).execute() }
    }

    func read<T: Decodable>(_ type: T.Type, _ request: () async throws -> PostgrestResponse<Void>) async throws -> T {
        let data: Data
        do {
            data = try await request().data
        } catch {
            throw Self.map(error)
        }
        if T.self == Ignored.self { return Ignored() as! T }
        return try LedgerJSON.decode(type, from: data)
    }

    static func map(_ error: any Error) -> any Error {
        if let e = error as? LedgerAPIError { return e }
        if let e = error as? PostgrestError {
            if e.code == "PGRST301" || e.code == "PGRST302" { return LedgerAPIError.notSignedIn }
            return LedgerAPIError.server(status: nil, code: e.code, message: e.message)
        }
        if let e = error as? AuthError {
            if case .sessionMissing = e { return LedgerAPIError.notSignedIn }
            return LedgerAPIError.server(status: nil, code: e.errorCode.rawValue, message: e.message)
        }
        if let e = error as? URLError { return LedgerAPIError.network(e.code.rawValue.description) }
        if let e = error as? HTTPError {
            return LedgerAPIError.server(status: e.response.statusCode, code: nil, message: "Server error \(e.response.statusCode)")
        }
        return error
    }
}

extension Optional where Wrapped == CalendarDay {
    var json: AnyJSON { map { .string($0.iso) } ?? .null }
}

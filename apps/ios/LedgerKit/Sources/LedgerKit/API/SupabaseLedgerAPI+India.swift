import Foundation
import Supabase

/// India mode's read (`india_overview`).
extension SupabaseLedgerAPI {
    public func indiaOverview(profileCode: String, period: ReturnsPeriod) async throws -> IndiaOverview {
        try await rpc("india_overview", IndiaOverview.self, [
            "p_profile_code": .string(profileCode), "p_period": .string(period.rawValue),
        ])
    }
}

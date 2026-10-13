import Foundation
import Supabase

/// Unusual spending ("This is fine") and AI-proposed SMS formats (accept / reject): PAR-9, PAR-14.
extension SupabaseLedgerAPI {
    public func anomalies(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [Anomaly] {
        try await rpc("anomalies", [Anomaly].self,
                      ["p_profile_code": .string(profileCode), "p_from": .string(from.iso), "p_to": .string(to.iso)])
    }

    public func dismissAnomaly(profileCode: String, txnCode: String) async throws {
        _ = try await rpc("dismiss_anomaly", Ignored.self,
                          ["p_profile_code": .string(profileCode), "p_txn_code": .string(txnCode)])
    }

    public func setSMSTemplateActive(templateCode: String, active: Bool) async throws {
        _ = try await rpc("set_sms_template_active", Ignored.self,
                          ["p_template_code": .string(templateCode), "p_active": .bool(active)])
    }

    /// The proposed formats of these `unparsed_sms` reviews, by review code: `rpc('review_context')`
    /// with only `review_code` and `template` selected, so no statement line, SMS or transaction
    /// crosses the wire (the template carries no `examples`).
    func proposedFormats(profileCode: String, reviewCodes: [String]) async throws -> [String: SMSFormatProposal] {
        guard !reviewCodes.isEmpty else { return [:] }
        let rows = try await read([ReviewFormatRow].self) {
            try await client.rpc("review_context", params: [
                "p_profile_code": AnyJSON.string(profileCode),
                "p_review_codes": .array(reviewCodes.map(AnyJSON.string)),
            ]).select("review_code,template").execute()
        }
        return ReviewFormatRow.byReview(rows)
    }
}

/// A `review_context` row with only `review_code` and `template` selected.
struct ReviewFormatRow: Decodable {
    let reviewCode: String
    let template: SMSFormatProposal?

    enum CodingKeys: String, CodingKey { case reviewCode, template }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewCode = try c.decode(String.self, forKey: .reviewCode)
        // A proposal this build can't read is left out: the review offers what it would without one.
        template = (try? c.decodeIfPresent(SMSFormatProposal.self, forKey: .template)) ?? nil
    }

    /// The proposals by review code; rows without one are left out.
    static func byReview(_ rows: [ReviewFormatRow]) -> [String: SMSFormatProposal] {
        var out: [String: SMSFormatProposal] = [:]
        for row in rows { if let template = row.template { out[row.reviewCode] = template } }
        return out
    }
}

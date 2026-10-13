import Foundation
import Testing
@testable import LedgerKit

@Suite("Insights parity (PAR-8): category change vs the previous period, top 20 merchants")
struct InsightsParityTests {
    @Test("merchants: Insights asks merchant_leaderboard for the top 20, as the web")
    @MainActor
    func topTwenty() async {
        let api = StubAPI()
        let model = InsightsModel(api: api)
        await model.load(profileCode: "prf_x")
        #expect(api.merchantLimits == [20])
        #expect(InsightsModel.merchantLimit == 20)
    }

    @Test("categories: the change chip reads the same to VoiceOver")
    func changeAccessibility() throws {
        let rows = try LedgerJSON.decode([CategorySpend].self, from: Data("""
        [{"category_code": "a", "name": "A", "color_token": null, "amount": "1200", "txn_count": 2, "share": "0.5",
          "prev_amount": "1000", "change": "0.2"},
         {"category_code": "b", "name": "B", "color_token": null, "amount": "840", "txn_count": 2, "share": "0.4",
          "prev_amount": "1000", "change": "-0.16"},
         {"category_code": "c", "name": "C", "color_token": null, "amount": "1000", "txn_count": 2, "share": "0.1",
          "prev_amount": "1000", "change": "0"},
         {"category_code": null, "name": "Uncategorised", "color_token": null, "amount": "10", "txn_count": 1,
          "share": "0.01", "prev_amount": "0", "change": null}]
        """.utf8))
        #expect(rows.map(\.changeChip.label) == ["+20%", "−16%", "±0%", "New"])
        #expect(rows.map(\.changeAccessibilityLabel) == [
            "Up 20% on the previous period, AED 1,000",
            "Down 16% on the previous period, AED 1,000",
            "Level with the previous period, AED 1,000",
            "New: nothing the period before",
        ])
    }
}

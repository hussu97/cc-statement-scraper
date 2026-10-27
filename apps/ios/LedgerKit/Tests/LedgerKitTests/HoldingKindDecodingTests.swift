import Foundation
import Testing
@testable import LedgerKit

/// A kind the server adds must never fail the whole Investments response on an installed build
/// (structured notes, 27 Oct 2026: build 40 threw on "structured_note").
struct HoldingKindDecodingTests {
    private func decode(_ json: String) throws -> HoldingKind {
        try LedgerJSON.decode([HoldingKind].self, from: Data("[\"\(json)\"]".utf8))[0]
    }

    @Test("every known kind decodes as itself, a structured note included")
    func known() throws {
        for kind in HoldingKind.allCases { #expect(try decode(kind.rawValue) == kind) }
        #expect(try decode("structured_note") == .structuredNote)
    }

    @Test("a kind this build doesn't know reads as a broker account instead of failing")
    func unknown() throws {
        #expect(try decode("crypto_wallet") == .broker)
    }

    @Test("the holding form never offers a structured note")
    func addable() {
        #expect(!HoldingKind.addable.contains(.structuredNote))
        #expect(HoldingKind.addable.count == HoldingKind.allCases.count - 1)
    }

    @Test("a valuation with a structured note decodes")
    func valuationWithNote() throws {
        var rows = try #require(try JSONSerialization.jsonObject(with: try fixture("holdings_valuation_kinds")) as? [String: Any])
        var holdings = try #require(rows["holdings"] as? [[String: Any]])
        var note = holdings[0]
        note["kind"] = "structured_note"
        note["holding_code"] = "hld_01m5yrg1qcsdkks478dtgyrbda"
        holdings.append(note)
        rows["holdings"] = holdings
        let v = try LedgerJSON.decode(HoldingsValuation.self, from: try JSONSerialization.data(withJSONObject: rows))
        #expect(v.holdings.contains { $0.kind == .structuredNote })
    }
}

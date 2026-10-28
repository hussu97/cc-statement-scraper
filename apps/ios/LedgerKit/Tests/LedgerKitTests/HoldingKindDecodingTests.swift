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
        #expect(try decode("savings_account") == .savingsAccount)
    }

    @Test("a kind this build doesn't know reads as a broker account instead of failing")
    func unknown() throws {
        #expect(try decode("crypto_wallet") == .broker)
        #expect(try decode("savings") == .broker)
    }

    @Test("the holding form never offers a structured note or a savings account; Investments lists savings accounts")
    func addable() {
        #expect(!HoldingKind.addable.contains(.structuredNote) && !HoldingKind.addable.contains(.savingsAccount))
        #expect(HoldingKind.addable.count == HoldingKind.allCases.count - 2)
        #expect(HoldingKind.listed.last == .savingsAccount && !HoldingKind.listed.contains(.structuredNote))
        #expect(!HoldingKind.savingsAccount.isEditable && HoldingKind.deposit.isEditable)
        let kind = HoldingKind.savingsAccount
        #expect(kind.label == "Savings account" && kind.groupTitle == "Savings accounts")
        #expect(kind.systemImage == "building.columns" && kind.explanation.contains("balance"))
        #expect(kind.listsFlows && !kind.takesFlows && !kind.recordsValue)
    }

    @Test("a valuation with a savings account decodes, and lists it in its own group")
    func valuationWithSavingsAccount() throws {
        var rows = try #require(try JSONSerialization.jsonObject(with: try fixture("holdings_valuation_kinds")) as? [String: Any])
        var holdings = try #require(rows["holdings"] as? [[String: Any]])
        var saver = holdings[0]
        saver["kind"] = "savings_account"
        saver["holding_code"] = "hld_01k60t7qjq83c4cjaqkpc79w6g"
        saver["rate_pct"] = "5.000"
        holdings.append(saver)
        rows["holdings"] = holdings
        let v = try LedgerJSON.decode(HoldingsValuation.self, from: try JSONSerialization.data(withJSONObject: rows))
        #expect(v.groups.last?.kind == .savingsAccount && v.groups.last?.holdings.count == 1)
    }

    @Test("a valuation with a structured note decodes")
    func valuationWithNote() throws {
        var rows = try #require(try JSONSerialization.jsonObject(with: try fixture("holdings_valuation_kinds")) as? [String: Any])
        var holdings = try #require(rows["holdings"] as? [[String: Any]])
        var note = holdings[0]
        note["kind"] = "structured_note"
        note["holding_code"] = "hld_01k5yrg1qcsdkks478dtgyrbda"
        holdings.append(note)
        rows["holdings"] = holdings
        let v = try LedgerJSON.decode(HoldingsValuation.self, from: try JSONSerialization.data(withJSONObject: rows))
        #expect(v.holdings.contains { $0.kind == .structuredNote })
        // Listed in their own card, not among the holdings.
        #expect(!v.groups.contains { $0.kind == .structuredNote })
    }
}

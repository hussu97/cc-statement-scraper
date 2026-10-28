import Foundation
import Testing
@testable import LedgerKit

/// A bank savings account shown under Investments (`savings_account`, 28 Oct 2026): valued at its
/// account's balance, fed by its transfers and interest, and out of Accounts' cash total.
@Suite("Investments: a savings account valued at its balance")
@MainActor
struct SavingsAccountInvestmentTests {
    static let holdingCode = "hld_01k60t7qjq83c4cjaqkpc79w6g"
    static let savingsCode = "acc_01k60t7d1rj0va9n5p6rnn51sw"
    static let currentCode = "acc_01k60t7d1tvehe036m2x125hxx"

    /// `holdings_valuation`'s row as the local stack sends it (no account_code).
    static let wire = """
    {"form": null, "kind": "savings_account", "name": "Neo Plus Saver - Balance", "grams": null, "karat": null,
     "metal": null, "notes": null, "quote": null, "units": null, "value": "502083.89", "purity": null,
     "symbol": null, "cost_aed": "491944.99", "currency": "AED", "fineness": null, "gain_aed": "20277.80",
     "gain_pct": "4.12", "rate_pct": "5.000", "principal": null, "value_aed": "502083.89", "flow_count": 11,
     "image_path": null, "income_aed": "10138.90", "link_exact": false, "acquired_on": null,
     "institution": "MASHREQ", "is_estimate": false, "maturity_on": null, "price_as_of": null,
     "value_as_of": "2026-09-30", "aed_per_gram": null, "holding_code": "hld_01k60t7qjq83c4cjaqkpc79w6g",
     "link_pattern": null, "change_24h_aed": "0.00", "price_is_stale": false}
    """

    static func saver() throws -> Holding { try LedgerJSON.decode(Holding.self, from: Data(wire.utf8)) }

    static func position() throws -> CashPosition {
        let json = """
        {"total_aed": "0.01", "complete": true, "stale_count": 1, "missing_count": 0,
         "as_of": "2026-09-30T19:59:59.999+00:00", "accounts": [
          {"account_code": "\(savingsCode)", "bank_code": "MASHREQ", "kind": "savings", "nickname": null,
           "account_ref": "6837", "currency": "AED", "balance": "502083.89", "balance_aed": "502083.89",
           "as_of": "2026-09-30T19:59:59.999+00:00", "anchor_source": "statement", "is_stale": true,
           "unpriced_count": 1, "investment_holding_code": "\(holdingCode)"},
          {"account_code": "\(currentCode)", "bank_code": "MASHREQ", "kind": "current", "nickname": null,
           "account_ref": "3297", "currency": "AED", "balance": "0.01", "balance_aed": "0.01",
           "as_of": "2026-09-30T19:59:59.999+00:00", "anchor_source": "statement", "is_stale": false,
           "unpriced_count": 0, "investment_holding_code": null}]}
        """
        return try LedgerJSON.decode(CashPosition.self, from: Data(json.utf8))
    }

    @Test("the holding decodes and reads as a savings account with its stated rate")
    func words() throws {
        let h = try Self.saver()
        #expect(h.kind == .savingsAccount && h.isSavingsAccount && h.ratePct == Decimal(5))
        #expect(h.savingsRateText == "5% a year")
        #expect(h.detail == "MASHREQ · Savings account · 5% a year")
        #expect(h.asOfText(today: CalendarDay(iso: "2026-10-28")!) == "Balance as of 30 Sep")
        #expect(h.valuedByAccountNote?.contains("bank account's balance") == true)
        #expect(SavingsAccountText.rateAYear(Decimal(string: "4.250")!) == "4.25% a year")
        let deposit = Holding(holdingCode: "hld_d", name: "Wio", kind: .deposit, ratePct: Decimal(4))
        #expect(deposit.savingsRateText == nil && deposit.valuedByAccountNote == nil)
        let noRate = Holding(holdingCode: "hld_s", name: "Saver", kind: .savingsAccount, institution: "FAB")
        #expect(noRate.savingsRateText == nil && noRate.detail == "FAB · Savings account")
        #expect(noRate.noGainText == "No value yet")
    }

    @Test("its screen offers the bank account and, to owners, cash again: no edit, value, flows or links")
    func actions() throws {
        let owner = try Self.saver().actions(canEdit: true)
        #expect(!owner.edit && !owner.recordValue && !owner.addFlow)
        #expect(owner.opensBankAccount && owner.stopShowing)
        let reader = try Self.saver().actions(canEdit: false)
        #expect(reader.opensBankAccount && !reader.stopShowing)
        let plan = Holding(holdingCode: "hld_p", name: "RL360", kind: .plan).actions(canEdit: true)
        #expect(plan.edit && plan.recordValue && plan.addFlow && !plan.opensBankAccount && !plan.stopShowing)
        let metal = Holding(holdingCode: "hld_m", name: "Bar", kind: .metal).actions(canEdit: true)
        #expect(metal.edit && !metal.addFlow)

        // The account's flows are its transactions: never removed or unlinked from the holding.
        let flow = HoldingFlow(flowCode: "flw_1", flowDate: CalendarDay(iso: "2026-09-30")!, kind: .income,
                               amount: Decimal(2000), amountAed: Decimal(2000), source: "account",
                               txnCode: "txn_1", txnDescription: "Interest", txnBankCode: "MASHREQ",
                               txnAccountKind: "savings")
        #expect(!flow.canRemove && flow.caption == "Income · MASHREQ account · from the account")

        // Linking a payment never offers it (TransactionLinkModel groups by the addable kinds).
        #expect(HoldingGroup.groups([try Self.saver()], kinds: HoldingKind.addable).isEmpty)
        #expect(HoldingGroup.groups([try Self.saver()]).map(\.kind) == [.savingsAccount])
    }

    @Test("Accounts lists the account as In Investments and leaves it out of the total's caveats")
    func accounts() throws {
        let p = try Self.position()
        let saver = try #require(p.accounts.first { $0.accountCode == Self.savingsCode })
        let current = try #require(p.accounts.first { $0.accountCode == Self.currentCode })
        #expect(saver.isShownAsInvestment && saver.investmentHoldingCode == Self.holdingCode)
        #expect(!current.isShownAsInvestment && current.investmentHoldingCode == nil)
        #expect(!saver.canShowAsInvestment(canEdit: true))
        #expect(current.canShowAsInvestment(canEdit: true) && !current.canShowAsInvestment(canEdit: false))
        // The unpriced savings account is not in the total, so it doesn't make the total "off".
        #expect(!p.caveats.contains { $0.contains("converted") })
        #expect(p.investedNote == "The total leaves out 1 account shown under Investments, where net worth counts it.")
        #expect(try Self.saver().bankAccount(in: p)?.accountCode == Self.savingsCode)
        #expect(try Self.saver().bankAccount(in: nil) == nil)
        // A server before this change sends no key: every account is cash.
        let old = BankAccountBalance(accountCode: "acc_x", bankCode: "FAB", kind: "savings", nickname: nil,
                                     accountRef: nil, balance: Decimal(1), balanceAed: Decimal(1), asOf: nil)
        #expect(!old.isShownAsInvestment && old.canShowAsInvestment(canEdit: true))
        let card = BankAccountBalance(accountCode: "acc_c", bankCode: "FAB", kind: "credit_card", nickname: nil,
                                      accountRef: nil, balance: nil, balanceAed: nil, asOf: nil)
        #expect(!card.canShowAsInvestment(canEdit: true))
    }

    @Test("the form's rate is optional, a percent up to 100, and goes up as typed")
    func draft() throws {
        let account = try #require(try Self.position().accounts.last)
        var d = TrackAccountDraft(account: account)
        #expect(d.validate() == nil && d.normalizedRate == nil && d.accountTitle == "Current ··· 3297")
        d.ratePct = " 5 "
        #expect(d.validate() == nil && d.normalizedRate == "5")
        d.ratePct = "4.25%"
        #expect(d.validate() == nil && d.normalizedRate == "4.25")
        for bad in ["abc", "101", "-1", "5.12345"] {
            d.ratePct = bad
            #expect(d.validate() != nil, "\(bad)")
        }
        #expect(d.savedMessage == "Current ··· 3297 is shown under Investments.")
        let refused = LedgerAPIError.server(status: 400, code: "22023", message: "rate_pct must be between 0 and 100")
        #expect(TrackAccountDraft.message(for: refused)
            == "Couldn't show it under Investments: rate_pct must be between 0 and 100.")
    }

    @Test("Show under Investments calls the RPC once, with the rate, and Investments tells the other screens")
    func track() async throws {
        let api = StubAPI()
        let m = InvestmentsModel(api: api, today: { CalendarDay(iso: "2026-10-28")! })
        var changed: [String] = []
        m.onChange = { changed.append($0) }
        let account = try #require(try Self.position().accounts.last)
        var d = TrackAccountDraft(account: account, ratePct: "5")
        #expect(await m.track(d, profileCode: "prf_a", canEdit: false) == HoldingDraft.ownerOnlyMessage)
        d.ratePct = "x"
        #expect(await m.track(d, profileCode: "prf_a", canEdit: true) != nil)
        #expect(api.trackedAccounts.isEmpty)
        d.ratePct = "5"
        #expect(await m.track(d, profileCode: "prf_a", canEdit: true) == nil)
        #expect(api.trackedAccounts.count == 1 && api.trackedAccounts[0].account == Self.currentCode
            && api.trackedAccounts[0].rate == "5" && api.trackedAccounts[0].name == nil)
        #expect(changed == ["prf_a"] && m.notice?.text == d.savedMessage)

        // Showing it as cash again closes the holding, in its own words.
        #expect(await m.close(try Self.saver(), profileCode: "prf_a", canEdit: true) == nil)
        #expect(api.closedHoldings == [Self.holdingCode])
        #expect(m.notice?.text == "Neo Plus Saver - Balance counts as cash again.")
    }

    @Test("its screen's flows: an empty state and a note about where they come from")
    func detail() async throws {
        let api = StubAPI()
        api.holdingDetailFixture = HoldingDetail()
        let m = HoldingDetailModel(holdingCode: Self.holdingCode, api: api, today: { CalendarDay(iso: "2026-10-28")! })
        await m.load(profileCode: "prf_a")
        let h = try Self.saver()
        #expect(m.noFlowsMessage(for: h)?.hasPrefix("No transfers or interest") == true)
        #expect(m.flowsNote(for: h) != nil && !m.showsValueHistory(for: h) && m.noValuesMessage(for: h) == nil)
        #expect(m.flowsNote(for: Holding(holdingCode: "hld_p", name: "RL360", kind: .plan)) == nil)
    }

    @Test("allocation names the class")
    func allocation() {
        let slice = AllocationSlice(assetClass: "savings_account", valueAed: Decimal(502_083.89))
        #expect(slice.label == "Savings accounts" && slice.colorToken == "cat-6")
    }
}

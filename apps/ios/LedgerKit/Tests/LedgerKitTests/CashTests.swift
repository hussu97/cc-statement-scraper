import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private func at(_ iso: String) -> Date { LedgerDates.parseTimestamp(iso)! }

/// 19:00 in Dubai on 20 Oct 2026.
private let now = at("2026-10-20T15:00:00Z")

private func account(_ code: String, kind: String = "current", nickname: String? = nil, ref: String? = "810001",
                     currency: String = "AED", balance: String? = "100", balanceAed: String? = "100",
                     asOf: String? = "2026-10-20T08:00:00Z", source: String? = "manual", stale: Bool = false,
                     unpriced: Int = 0) -> BankAccountBalance {
    BankAccountBalance(accountCode: code, bankCode: "ADCB", kind: kind, nickname: nickname, accountRef: ref,
                       currency: currency, balance: balance.map(dec), balanceAed: balanceAed.map(dec),
                       asOf: asOf.map(at), anchorSource: source, isStale: stale, unpricedCount: unpriced)
}

@Suite("Cash position: decoding and words")
struct CashPositionTests {
    @Test("cash_position decodes exact decimals, times and the accounts in the server's order")
    func decodes() throws {
        let p = try LedgerJSON.decode(CashPosition.self, from: try fixture("cash_position"))
        #expect(p.totalAed == dec("108385.90") && p.totalText == "AED 108,385.90")
        #expect(p.complete && p.staleCount == 1 && p.missingCount == 0 && p.hasAccounts)
        #expect(p.asOf == at("2026-10-06T12:00:00Z"))
        #expect(p.asOfText(now: now) == "As of 6 Oct")
        #expect(p.caveats == ["1 balance is over a week old."])
        #expect(p.caveatTone == .info)

        let adcb = p.accounts[0], fab = p.accounts[1]
        #expect(adcb.title == "Salary account" && adcb.subtitle == "Current ··· 810001")
        #expect(adcb.detail == "ADCB · Current ··· 810001" && account("a").detail == "ADCB")
        #expect(adcb.balance == dec("28650.40") && adcb.balanceText == "AED 28,650.40")
        #expect(adcb.staleLabel == "Over a week old")
        #expect(adcb.asOfText(now: now) == "As of 6 Oct · from SMS")
        #expect(fab.kind == "savings" && fab.subtitle == "Savings ··· 9001" && fab.staleLabel == nil)
        #expect(fab.asOfText(now: now) == "As of today, 16:19 · from SMS")
        #expect(fab.balanceDraftText == "79735.5")
    }

    @Test("caveats: missing balances, unconverted amounts and stale ones, singular and plural")
    func caveats() {
        let p = CashPosition(totalAed: 100, complete: false, staleCount: 2, missingCount: 2, asOf: nil, accounts: [
            account("a", balance: nil, balanceAed: nil, asOf: nil),
            account("b", balance: nil, balanceAed: nil, asOf: nil),
            account("c", currency: "USD", balance: "50", balanceAed: nil),
        ])
        #expect(p.caveats == [
            "2 accounts have no balance yet, so the total leaves them out.",
            "Some amounts aren't converted to AED yet, so the total may be off.",
            "2 balances are over a week old.",
        ])
        #expect(p.caveatTone == .warn)
        #expect(p.asOfText(now: now) == nil)
        let one = CashPosition(totalAed: 0, complete: false, staleCount: 0, missingCount: 1, asOf: nil,
                               accounts: [account("a", balance: nil, balanceAed: nil, asOf: nil)])
        #expect(one.caveats == ["1 account has no balance yet, so the total leaves it out."])
        #expect(one.accounts[0].balanceText == "No balance yet" && one.accounts[0].asOfText(now: now) == nil)
        #expect(one.accounts[0].staleLabel == nil && one.accounts[0].balanceDraftText == "")
        let unpriced = CashPosition(totalAed: 100, complete: false, staleCount: 0, missingCount: 0, asOf: nil,
                                    accounts: [account("a", unpriced: 2)])
        #expect(unpriced.caveats == ["Some amounts aren't converted to AED yet, so the total may be off."])
        let none = CashPosition(totalAed: 0, complete: true, staleCount: 0, missingCount: 0, asOf: nil, accounts: [])
        #expect(!none.hasAccounts && none.caveats.isEmpty)
        #expect(CashPosition.noAccountsMessage(canEdit: true).contains("with +"))
        #expect(CashPosition.noAccountsMessage(canEdit: false) == "No bank accounts yet. An owner of this ledger can add them.")
        #expect(one.accounts[0].updateLabel == "Add balance" && account("a").updateLabel == "Update balance")
    }

    @Test("names: nickname first, else kind and ref; a foreign balance in its own currency")
    func names() {
        #expect(account("a").title == "Current ··· 810001" && account("a").subtitle == nil)
        #expect(account("a", kind: "savings", ref: nil).title == "Savings account")
        #expect(account("a", nickname: "", ref: "12").title == "Current ··· 12")
        #expect(account("a", kind: "fixed").kindAndRef == "Fixed ··· 810001")
        #expect(account("a", currency: "USD", balance: "-12.5").balanceText == "USD -12.50")
        #expect(account("a").asOfText(now: now) == "As of today, 12:00 · entered")
        #expect(account("a", source: nil).asOfText(now: now) == "As of today, 12:00")
    }

    @Test("as of: today and yesterday with the Dubai time, then days, then the date")
    func asOf() {
        #expect(CashText.asOf(at("2026-10-20T00:30:00Z"), now: now) == "As of today, 04:30")
        // 23:30 UTC on the 19th is already the 20th in Dubai.
        #expect(CashText.asOf(at("2026-10-19T23:30:00Z"), now: now) == "As of today, 03:30")
        #expect(CashText.asOf(at("2026-10-19T10:00:00Z"), now: now) == "As of yesterday, 14:00")
        #expect(CashText.asOf(at("2026-10-17T10:00:00Z"), now: now) == "As of 3 days ago")
        #expect(CashText.asOf(at("2026-10-14T10:00:00Z"), now: now) == "As of 6 days ago")
        #expect(CashText.asOf(at("2026-10-13T10:00:00Z"), now: now) == "As of 13 Oct")
        #expect(CashText.asOf(at("2025-12-30T10:00:00Z"), now: now) == "As of 30 Dec 2025")
        #expect(CashText.asOf(at("2026-10-21T10:00:00Z"), now: now) == "As of today, 14:00")   // clock skew
    }

    @Test("filter_meta's bank accounts read by bank and name; cards keep their nickname")
    func filterMetaAccounts() throws {
        let json = """
        {"accounts":[{"account_code":"acc_c","bank_code":"FAB","nickname":"Cashback","product_name":null,
          "kind":"credit_card","account_ref":null},
         {"account_code":"acc_b","bank_code":"ADCB","nickname":null,"product_name":null,"kind":"current",
          "account_ref":"810001"},
         {"account_code":"acc_old","bank_code":"ENBD","nickname":null,"product_name":"Platinum"}],
         "cards":[],"categories":[],"banks":[],"date_range":null}
        """
        let meta = try LedgerJSON.decode(FilterMeta.self, from: Data(json.utf8))
        #expect(meta.accounts.map(\.title) == ["Cashback", "ADCB Current ··· 810001", "Platinum"])
        #expect(meta.accounts.map(\.isBankAccount) == [false, true, false])
    }
}

@Suite("Cash flow: grouping the server's flows")
struct CashFlowTests {
    @Test("cash_flow decodes JSON-number amounts exactly and groups a month newest first")
    func groups() throws {
        let rows = try LedgerJSON.decode([CashFlowRow].self, from: try fixture("cash_flow"))
        #expect(rows.first == CashFlowRow(month: day("2026-08-01"), flow: "net", amountAed: dec("-9111.51"), txnCount: 58))
        let months = CashFlow.months(rows)
        #expect(months.map(\.month) == [day("2026-10-01"), day("2026-09-01"), day("2026-08-01")])

        let oct = months[0]
        #expect(oct.groups.map(\.kind) == [.moneyIn, .committed, .spent, .unfiledOut])
        #expect(oct.groups.map { $0.lines.map(\.flow) } == [["income"], ["support", "saving"], ["spend"], ["money_out"]])
        #expect(oct.groups[1].lines.map(\.label) == ["Support", "Saving & investing"])
        #expect(oct.groups[1].lines[0].amountText == "AED 23,700.00" && oct.groups[1].lines[0].countText == "1 transaction")
        #expect(oct.groups[2].lines[0].amountAed == dec("1101.10") && oct.groups[2].lines[0].countText == "14 transactions")
        // Net is the server's row, never a sum of the groups.
        #expect(oct.net == dec("16298.90") && oct.netText == "+AED 16,298.90" && oct.netTone == .positive)
        #expect(oct.title == "October 2026" && !oct.isEmpty)

        let aug = months[2]
        #expect(aug.groups.map(\.kind) == [.spent] && aug.netText == "−AED 9,111.51" && aug.netTone == .warn)
    }

    @Test("moves carry their note; empty and unknown flows are left out; a month with no net row has no net")
    func movesAndGaps() {
        let m = day("2026-09-01")
        let months = CashFlow.months([
            CashFlowRow(month: m, flow: "card_repayment", amountAed: dec("4200"), txnCount: 1),
            CashFlowRow(month: m, flow: "internal_out", amountAed: dec("1000"), txnCount: 1),
            CashFlowRow(month: m, flow: "internal_in", amountAed: 0, txnCount: 0),
            CashFlowRow(month: m, flow: "spend_transfer", amountAed: dec("6500"), txnCount: 1),
            CashFlowRow(month: m, flow: "money_in", amountAed: dec("300"), txnCount: 2),
            CashFlowRow(month: m, flow: "cash_withdrawal", amountAed: dec("500"), txnCount: 1),
        ])
        let sep = months[0]
        #expect(sep.groups.map(\.kind) == [.moneyIn, .spent, .moves])
        #expect(sep.groups[2].lines.map(\.label) == ["Card repayments", "To your other accounts"])
        #expect(sep.groups[2].kind.note == "Card repayments and moves between your own accounts don't change net.")
        #expect(sep.groups[0].lines[0].label == "Other money in, not filed")
        #expect(sep.groups[1].lines[0].label == "Paid by transfer")
        #expect(sep.net == nil && sep.netText == nil && sep.netTone == .neutral)
        #expect(CashFlowLine.label(for: "cash_withdrawal") == "Cash Withdrawal")
        #expect(CashFlow.signed(0) == "AED 0.00")
    }

    @Test("months: the last six to today's, an empty month for one the server skipped, and its message")
    func months() {
        let today = day("2026-10-20")
        #expect(CashFlow.monthChoices(today: today) == [
            day("2026-10-01"), day("2026-09-01"), day("2026-08-01"), day("2026-07-01"), day("2026-06-01"), day("2026-05-01"),
        ])
        let empty = CashFlow.month(day("2026-07-15"), in: [])
        #expect(empty.month == day("2026-07-01") && empty.isEmpty && empty.net == nil)
        #expect(CashFlow.emptyMessage(day("2026-10-01"), today: today) == "No money moved in October yet.")
        #expect(CashFlow.emptyMessage(day("2026-07-01"), today: today) == "No money moved in July 2026.")
    }
}

@Suite("Bank account forms: Update balance and Add bank account")
struct BankAccountDraftTests {
    @Test("a balance is digits with an optional minus and at most two decimals, as record_balance checks")
    func balance() {
        func ok(_ s: String) -> Bool { UpdateBalanceDraft(accountCode: "a", accountTitle: "t", amount: s).validate() == nil }
        for good in ["0", "28650.40", "28,650.4", " 1 200 ", "-120", "\u{2212}120.50", "999999999999.99"] {
            #expect(ok(good), "\(good)")
        }
        for bad in ["", "-", ".5", "5.", "1.234", "abc", "1e5", "--1", "+5", "1234567890123", "12a"] {
            #expect(!ok(bad), "\(bad)")
        }
        #expect(UpdateBalanceDraft(accountCode: "a", accountTitle: "t", amount: "\u{2212}28,650.40").normalizedAmount
                == "-28650.40")
        #expect(UpdateBalanceDraft(accountCode: "a", accountTitle: "t", amount: "x").validate()
                == "Enter the balance as a number, e.g. 28650.40, or -120 if overdrawn.")
        let fromRow = UpdateBalanceDraft(account: account("acc_1", nickname: "Salary", balance: "28650.40"))
        #expect(fromRow.accountTitle == "ADCB · Salary" && fromRow.amount == "28650.4" && fromRow.id == "acc_1")
    }

    @Test("record_balance's refusals in plain words")
    func balanceErrors() {
        func msg(_ code: String) -> String {
            UpdateBalanceDraft.message(for: LedgerAPIError.server(status: nil, code: code, message: "raw"))
        }
        #expect(msg("42501") == "Only the ledger's owners can update balances.")
        #expect(msg("22023") == "Enter the balance as a number with at most two decimals.")
        #expect(msg("P0002") == "This account isn't in the ledger any more. Pull to refresh.")
        #expect(msg("XX000") == "raw")
        #expect(UpdateBalanceDraft.message(for: LedgerAPIError.network("-1009")) == "No connection to Ledger.")
    }

    @Test("a new account needs a bank and 3 to 12 digits; spaces and mask dots are dropped, a blank nickname is none")
    func add() {
        var d = AddBankAccountDraft()
        #expect(d.validate() == "Choose the bank.")
        d.bankCode = "EIB"
        for bad in ["", "12", "1234567890123", "12a4"] {
            d.accountRef = bad
            #expect(d.validate() == "Enter the 3 to 12 digits at the end of the account number, as your bank's SMS show them.")
        }
        d.accountRef = " ··· 81 0001 "
        #expect(d.validate() == nil && d.normalizedRef == "810001")
        d.accountRef = "XXXX4301"
        #expect(d.normalizedRef == "4301")
        d.nickname = "   "
        #expect(d.normalizedNickname == nil)
        d.nickname = " Rent pot "
        #expect(d.normalizedNickname == "Rent pot")
        d.kind = .savings
        #expect(d.savedMessage == "EIB savings account added.")
    }

    @Test("create_bank_account's refusals in plain words")
    func addErrors() {
        let d = AddBankAccountDraft(bankCode: "ADCB", kind: .current, accountRef: "810001")
        func msg(_ code: String) -> String { d.message(for: LedgerAPIError.server(status: nil, code: code, message: "raw")) }
        #expect(msg("23505") == "The ADCB account ending 810001 is already in this ledger.")
        #expect(msg("22023") == "Check the account type and the digits: 3 to 12 from the end of the account number.")
        #expect(msg("P0002") == "Bank Ledger doesn't know this bank yet.")
        #expect(msg("42501") == "Only the ledger's owners can add accounts.")
        #expect(msg("XX000") == "raw")
    }

    @Test("the bank list is by name: the banks table when loaded, else the seed's names")
    func banks() {
        let seed = AddBankAccountDraft.bankChoices([])
        #expect(seed.count == BankDirectory.knownNames.count)
        #expect(seed.first?.name == "Abu Dhabi Commercial Bank")
        let rows = AddBankAccountDraft.bankChoices([BankInfo(bankCode: "WIO", name: "Wio Bank"),
                                                    BankInfo(bankCode: "CBD", name: "Commercial Bank of Dubai")])
        #expect(rows.map(\.bankCode) == ["CBD", "WIO"])
    }
}

@MainActor
@Suite("Cash & accounts screen model")
struct CashModelTests {
    static func api() throws -> StubAPI {
        let api = StubAPI()
        api.cashPositionFixture = try LedgerJSON.decode(CashPosition.self, from: try fixture("cash_position"))
        api.cashFlowRows = try LedgerJSON.decode([CashFlowRow].self, from: try fixture("cash_flow"))
        return api
    }

    @Test("loads balances and six months of flow; the current month is selected and every month listed")
    func load() async throws {
        let api = try Self.api()
        let model = CashModel(api: api, today: { day("2026-10-20") })
        await model.loadIfNeeded(profileCode: "prf_a")
        await model.loadIfNeeded(profileCode: "prf_a")   // already on screen
        #expect(api.calls("cashPosition") == 1 && api.calls("cashFlow") == 1)
        #expect(api.cashFlowRanges.first! == (day("2026-05-01"), day("2026-10-31")))
        #expect(model.state.value?.position.accounts.count == 2 && model.state.value?.flowError == nil)
        #expect(model.selected?.month == day("2026-10-01") && model.selected?.net == dec("16298.90"))
        #expect(model.monthNets.map(\.month) == CashFlow.monthChoices(today: day("2026-10-20")))
        #expect(model.monthNets.map(\.netText) == ["+AED 16,298.90", "−AED 10,729.97", "−AED 9,111.51", nil, nil, nil])
        model.selectedMonth = day("2026-07-01")
        #expect(model.selected?.isEmpty == true)
        #expect(model.emptyMessage(for: model.selectedMonth) == "No money moved in July 2026.")
        model.reset()
        #expect(model.state.value == nil && model.selectedMonth == day("2026-10-01"))
    }

    @Test("a failed cash flow keeps the accounts; a failed position fails the screen")
    func failures() async throws {
        let api = try Self.api()
        api.cashFlowError = .server(status: nil, code: "57014", message: "timeout")
        let model = CashModel(api: api, today: { day("2026-10-20") })
        await model.load(profileCode: "prf_a")
        #expect(model.state.value?.position.hasAccounts == true)
        #expect(model.state.value?.flowError == "timeout" && model.state.value?.months.isEmpty == true)

        api.cashPositionFixture = nil
        let failing = CashModel(api: api, today: { day("2026-10-20") })
        await failing.load(profileCode: "prf_a")
        #expect(failing.state.value == nil && failing.state.errorMessage == "No connection to Ledger.")
    }

    @Test("update balance: refused input never reaches the server; a saved one reloads and tells Overview")
    func updateBalance() async throws {
        let api = try Self.api()
        let model = CashModel(api: api, today: { day("2026-10-20") })
        var told: [String] = []
        model.onChange = { told.append($0) }
        await model.load(profileCode: "prf_a")
        var draft = UpdateBalanceDraft(accountCode: "acc_1", accountTitle: "ADCB · Salary", amount: "12.345")
        #expect(await model.updateBalance(draft, profileCode: "prf_a") != nil)
        #expect(api.recordedBalances.isEmpty)

        draft.amount = "29,100.5"
        #expect(await model.updateBalance(draft, profileCode: "prf_a") == nil)
        #expect(api.recordedBalances.map(\.balance) == ["29100.5"] && api.recordedBalances.map(\.account) == ["acc_1"])
        #expect(model.notice == CashModel.Notice(text: "Balance updated.", isError: false))
        #expect(api.calls("cashPosition") == 2 && told == ["prf_a"])

        api.cashWriteError = .server(status: nil, code: "42501", message: "nope")
        #expect(await model.updateBalance(draft, profileCode: "prf_a") == "Only the ledger's owners can update balances.")
        #expect(!model.isSaving && told == ["prf_a"])
    }

    @Test("add account: validated, sent normalised, then the list reloads")
    func addAccount() async throws {
        let api = try Self.api()
        let model = CashModel(api: api, today: { day("2026-10-20") })
        await model.load(profileCode: "prf_a")
        var draft = AddBankAccountDraft(bankCode: "EIB", kind: .current, accountRef: "12")
        #expect(await model.addAccount(draft, profileCode: "prf_a") != nil)
        draft.accountRef = "··· 4301"
        draft.nickname = "  "
        #expect(await model.addAccount(draft, profileCode: "prf_a") == nil)
        #expect(api.createdBankAccounts.count == 1)
        #expect(api.createdBankAccounts[0].bank == "EIB" && api.createdBankAccounts[0].ref == "4301")
        #expect(api.createdBankAccounts[0].nickname == nil && api.createdBankAccounts[0].kind == .current)
        #expect(model.notice?.text == "EIB current account added." && api.calls("cashPosition") == 2)

        api.cashWriteError = .server(status: nil, code: "23505", message: "dup")
        #expect(await model.addAccount(draft, profileCode: "prf_a") == "The EIB account ending 4301 is already in this ledger.")
    }

    @Test("Overview: the cash tile shows for a ledger with a bank account, and not when cash_position fails")
    func overviewTile() async throws {
        let api = try Self.api()
        api.overviewFixture = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let overview = OverviewModel(api: api)
        await overview.load(profileCode: "prf_a")
        #expect(overview.state.value?.showsCashTile == true)
        #expect(overview.state.value?.cash?.totalAed == dec("108385.90"))

        api.cashPositionFixture = CashPosition(totalAed: 0, complete: true, staleCount: 0, missingCount: 0, asOf: nil,
                                               accounts: [])
        await overview.load(profileCode: "prf_a")
        #expect(overview.state.value?.showsCashTile == false)

        api.cashPositionFixture = nil
        await overview.load(profileCode: "prf_a")
        #expect(overview.state.value != nil && overview.state.value?.cash == nil)   // Overview still loads
    }

    @Test("ledger screens: a write on Cash refreshes Overview; Realtime refreshes Cash once opened; a switch clears it")
    func screens() async throws {
        let api = try Self.api()
        api.overviewFixture = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let s = LedgerScreens(api: api, today: { day("2026-10-20") })
        await s.select("prf_a")
        await s.refresh(after: ["transactions"])
        #expect(api.calls("cashFlow") == 0)                     // never opened
        await s.cash.loadIfNeeded(profileCode: "prf_a")
        await s.refresh(after: ["sms_messages"])
        #expect(api.calls("cashFlow") == 2)
        let overviewLoads = api.calls("overview")
        _ = await s.cash.updateBalance(UpdateBalanceDraft(accountCode: "a", accountTitle: "t", amount: "1"),
                                       profileCode: "prf_a")
        #expect(api.calls("overview") == overviewLoads + 1)
        await s.select("prf_b")
        #expect(s.cash.state.value == nil)
        s.stop()
    }
}

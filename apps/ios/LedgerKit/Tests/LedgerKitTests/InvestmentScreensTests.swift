import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

/// A screen that saves links: records them, or fails with `error`.
@MainActor
private final class LinkTarget: TransactionEditing {
    var links: [(txn: String, holding: String?)] = []
    var error: LedgerAPIError?
    func saveCategory(_ txn: LedgerTransaction, to categoryCode: String?, applyToMerchant: Bool, profileCode: String) async throws {}
    func saveEdit(_ txn: LedgerTransaction, _ edit: TransactionEdit, profileCode: String) async throws {}
    func saveLink(_ txn: LedgerTransaction, holdingCode: String?, profileCode: String) async throws {
        if let error { throw error }
        links.append((txn.txnCode, holdingCode))
    }
}

@Suite("Investments: the screens' models")
@MainActor
struct InvestmentScreensTests {
    static func api() throws -> StubAPI {
        let api = StubAPI()
        api.valuationFixture = try KindsFixtures.valuation()
        api.holdingDetailFixture = try KindsFixtures.detail()
        api.returnsFixtures = [.all: try KindsFixtures.returns(), .ytd: try KindsFixtures.returns("holding_returns_ytd"),
                               .twelveMonths: try KindsFixtures.returns()]
        return api
    }

    @Test("Investments loads all-time returns with the holdings; another period loads once when picked")
    func returns() async throws {
        let api = try Self.api()
        let m = InvestmentsModel(api: api, today: { day("2026-10-21") })
        await m.load(profileCode: "prf_a")
        #expect(m.selectedReturns.value?.total.annualPct != nil && api.returnsCalls == [.all])
        await m.selectReturns(.ytd, profileCode: "prf_a")
        #expect(m.returnsPeriod == .ytd && m.selectedReturns.value?.total.complete == false)
        await m.selectReturns(.all, profileCode: "prf_a")
        await m.selectReturns(.ytd, profileCode: "prf_a")
        #expect(api.returnsCalls == [.all, .ytd])
        await m.refresh(profileCode: "prf_a")
        #expect(api.returnsCalls.last == .ytd && m.returns[.all] == nil)
        api.returnsFixtures = [:]
        await m.selectReturns(.twelveMonths, profileCode: "prf_a")
        #expect(m.selectedReturns.errorMessage != nil && m.state.value != nil)
        m.reset()
        #expect(m.returnsPeriod == .all && m.returns.isEmpty)
    }

    @Test("a holding's screen: its flows, values and its row in every period's returns")
    func detail() async throws {
        let api = try Self.api()
        let m = HoldingDetailModel(holdingCode: KindsFixtures.plan, api: api, today: { day("2026-10-21") })
        await m.load(profileCode: "prf_a")
        #expect(m.flows.count == 9 && m.valuations.count == 2)
        #expect(m.figures(for: .all)?.annualPct != nil && m.figures(for: .ytd)?.complete == false)
        let plan = try KindsFixtures.holding("RL360 plan")
        #expect(m.noFlowsMessage(for: plan) == nil && m.noValuesMessage(for: plan) == nil)
        api.holdingDetailFixture = HoldingDetail()
        await m.load(profileCode: "prf_a")
        #expect(m.noFlowsMessage(for: plan)?.contains("“RL360”") == true && m.noValuesMessage(for: plan) == "No value recorded yet.")
        api.holdingDetailFixture = nil
        await m.load(profileCode: "prf_a")
        #expect(m.detail.errorMessage != nil)
    }

    @Test("writes: owners only, validated first; a linked flow unlinks, a manual one is removed; the tab hears")
    func writes() async throws {
        let api = try Self.api()
        var told: [String] = []
        let m = HoldingDetailModel(holdingCode: KindsFixtures.plan, api: api, today: { day("2026-10-21") }) { told.append($0) }
        await m.load(profileCode: "prf_a")
        let plan = try KindsFixtures.holding("RL360 plan")
        var flow = m.newFlow(for: plan)
        #expect(await m.addFlow(flow, profileCode: "prf_a", canEdit: false) == HoldingDraft.ownerOnlyMessage)
        #expect(await m.addFlow(flow, profileCode: "prf_a", canEdit: true)?.hasPrefix("Enter the amount") == true)
        flow.amount = "2000"
        #expect(await m.addFlow(flow, profileCode: "prf_a", canEdit: true) == nil)
        #expect(api.addedFlows.last?.amount == "2000" && m.notice?.text == "Money in added to RL360 plan." && told == ["prf_a"])

        let linked = try #require(m.flows.first)
        #expect(await m.remove(linked, profileCode: "prf_a", canEdit: true) == nil)
        #expect(api.links.last?.txn == linked.txnCode && api.links.last?.holding == nil && api.removedFlows.isEmpty)
        let manual = try #require(m.flows.last)
        #expect(await m.remove(manual, profileCode: "prf_a", canEdit: true) == nil)
        #expect(api.removedFlows == [manual.flowCode] && m.notice?.text == "Removed.")

        var value = m.newValue(for: plan)
        value.amount = "54100"
        #expect(await m.recordValue(value, profileCode: "prf_a", canEdit: true) == nil)
        #expect(api.recordedValues.last?.value == "54100" && told.count == 4)

        api.holdingWriteError = .server(status: nil, code: "22023", message: "a plan or broker account takes a value")
        #expect(await m.recordValue(value, profileCode: "prf_a", canEdit: true) == "Check the holding: a plan or broker account takes a value.")
    }

    @Test("Investments' detail models write through to the tab: it reloads and tells Overview")
    func detailRefreshesTab() async throws {
        let api = try Self.api()
        let tab = InvestmentsModel(api: api, today: { day("2026-10-21") })
        var told: [String] = []
        tab.onChange = { told.append($0) }
        await tab.load(profileCode: "prf_a")
        let detail = tab.detailModel(for: KindsFixtures.plan)
        var value = detail.newValue(for: try #require(tab.holding(KindsFixtures.plan)))
        value.amount = "1"
        #expect(await detail.recordValue(value, profileCode: "prf_a", canEdit: true) == nil)
        #expect(told == ["prf_a"] && api.calls("holdingsValuation") == 2)
    }

    @Test("link: choose a holding, unlink for good; no AED amount can't be linked; refusals in words")
    func link() async throws {
        let api = try Self.api()
        let target = LinkTarget()
        let row = txn("txn_1")
        let m = TransactionLinkModel(transaction: row, profileCode: "prf_a", api: api, target: target)
        #expect(!m.isLinked && m.statusText == "Not linked" && m.canLink)
        await m.loadChoices()
        await m.loadChoices()
        #expect(m.choices.value?.count == 8 && api.calls("holdingsValuation") == 1)
        let plan = try #require(m.choices.value?.first { $0.kind == .plan })
        #expect(await m.link(plan))
        #expect(m.statusText == "RL360 plan" && target.links.last?.holding == plan.holdingCode)
        #expect(await m.link(plan) && target.links.count == 1)
        #expect(await m.unlink())
        #expect(!m.isLinked && target.links.last?.holding == nil)
        target.error = .server(status: nil, code: "22023", message: "the transaction has no AED amount yet")
        #expect(await m.link(plan) == false)
        #expect(m.errorMessage == "Couldn't link it: the transaction has no AED amount yet.")
        #expect(TransactionLinkModel.message(for: LedgerAPIError.server(status: nil, code: "42501", message: "x"))
                == HoldingDraft.ownerOnlyMessage)
    }

    @Test("the screens save links through the API and re-read the row")
    func targets() async throws {
        let api = try Self.api()
        api.transactionRows["prf_a"] = [txn("txn_1")]
        let activity = ActivityModel(api: api)
        var told: [String] = []
        activity.onLinkChange = { told.append($0) }
        try await activity.saveLink(txn("txn_1"), holdingCode: KindsFixtures.plan, profileCode: "prf_a")
        #expect(api.links.last?.holding == KindsFixtures.plan && told == ["prf_a"] && api.calls("transactionsByCode") == 1)
        let detail = TransactionDetailModel(transaction: txn("txn_1"), profileCode: "prf_a", api: api)
        #expect(detail.linker(target: activity).transaction.txnCode == "txn_1")
    }
}

import Foundation
import Testing
@testable import LedgerKit

/// IOS-23: an empty ledger shows a checklist, not "AED 0 · Same as this time last month".
@MainActor
@Suite("Overview: the empty-ledger checklist")
struct SetupChecklistTests {
    /// `overview` for a ledger with nothing in it, optionally with an SMS received.
    func emptyOverview(lastSMS: String? = nil) throws -> Overview {
        let json = """
        {"month": "2026-10-01", "spend": "0", "spend_prev_month": "0", "spend_prev_month_to_date": "0",
         "spend_avg_3m": "0", "change_vs_prev_month_to_date": null, "change_vs_avg_3m": null, "payments": "0",
         "outstanding": "0", "outstanding_complete": true, "outstanding_has_estimate": false,
         "pending_count": 0, "pending_amount": "0", "uncategorized_count": 0, "open_reviews": 0,
         "last_sms_at": \(lastSMS.map { "\"\($0)\"" } ?? "null"),
         "top_categories": [], "accounts": [], "recent": []}
        """
        return try LedgerJSON.decode(Overview.self, from: Data(json.utf8))
    }

    @Test("a ledger with transactions or cards gets no checklist")
    func notForData() throws {
        let full = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        #expect(SetupChecklist.make(overview: full, uploads: 0, members: MemberCount(members: 1)) == nil)
        #expect(!SetupChecklist.isEmptyLedger(full))
    }

    @Test("nothing done: three steps to do, in order")
    func nothingDone() throws {
        let list = try #require(SetupChecklist.make(overview: try emptyOverview(), uploads: 0, members: MemberCount(members: 1)))
        #expect(list.steps.map(\.kind) == [.sms, .statement, .invite])
        #expect(list.steps.allSatisfy { $0.status == .todo })
        #expect(list.progress == "0 of 3 done")
        #expect(list.steps[0].title == "Set up SMS capture")
        #expect(list.steps[2].detail.contains("Settings → Members"))
    }

    @Test("each step is ticked by server data: an SMS received, an upload, a second member or invite")
    func ticks() throws {
        let list = try #require(SetupChecklist.make(overview: try emptyOverview(lastSMS: "2026-10-08T05:12:44+00:00"),
                                                    uploads: 1, members: MemberCount(members: 2)))
        #expect(list.steps.allSatisfy { $0.status == .done })
        #expect(list.progress == "3 of 3 done")
        #expect(list.steps[1].detail == "A statement is in. Its cards show here once it has been read.")
    }

    @Test("a pending invite says the invite was sent, never that someone has access")
    func pendingInvite() throws {
        let pending = try #require(SetupChecklist.make(overview: try emptyOverview(), uploads: 0,
                                                       members: MemberCount(members: 1, pendingInvites: 1)))
        #expect(pending.steps[2].status == .done)
        #expect(pending.steps[2].detail == "Invite sent. They get access once they accept it.")
        let joined = try #require(SetupChecklist.make(overview: try emptyOverview(), uploads: 0,
                                                      members: MemberCount(members: 2, pendingInvites: 1)))
        #expect(joined.steps[2].detail == "Someone else has access to this ledger.")
    }

    @Test("an unreadable count is unknown, never claimed done or undone")
    func unknown() throws {
        let list = try #require(SetupChecklist.make(overview: try emptyOverview(), uploads: nil, members: nil))
        #expect(list.steps.map(\.status) == [.todo, .unknown, .unknown])
    }

    @Test("the model reads uploads and members only for an empty ledger; a failed read doesn't fail Overview")
    func model() async throws {
        let api = StubAPI()
        api.overviewFixture = try emptyOverview()
        api.memberCountValue = nil   // e.g. a super admin who isn't a member
        let model = OverviewModel(api: api)
        await model.load(profileCode: "prf_a")
        let content = try #require(model.state.value)
        #expect(content.setup?.steps.map(\.status) == [.todo, .todo, .unknown])
        #expect(api.calls("documents") == 1 && api.calls("memberCount") == 1)

        api.overviewFixture = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        await model.load(profileCode: "prf_a")
        #expect(try #require(model.state.value).setup == nil)
        #expect(api.calls("documents") == 1 && api.calls("memberCount") == 1)   // not asked again
    }
}

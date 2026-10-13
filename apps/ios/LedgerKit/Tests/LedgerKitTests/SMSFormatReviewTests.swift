import Foundation
import Testing
@testable import LedgerKit

private let reviewCode = "rev_01hzy3k8w9m2n4p6q8r0s2t4c1"
private let templateCode = "tpl_01hzy3k8w9m2n4p6q8r0s2t4c1"

private func formats() throws -> [String: SMSFormatProposal] {
    ReviewFormatRow.byReview(try LedgerJSON.decode([ReviewFormatRow].self, from: try fixture("review_context_formats")))
}

private func unparsed(_ code: String = reviewCode) -> MatchReview {
    MatchReview(reviewCode: code, subjectType: "sms", subjectCode: "sms_01hzy3k8w9m2n4p6q8r0s2t4c1",
                reason: "unparsed_sms", candidates: [.init(txnCode: nil, bankCode: nil, last4: nil, templateCode: templateCode)])
}

@Suite("Review: accept or reject a proposed SMS format on the phone (PAR-14)")
struct SMSFormatReviewTests {
    @Test("review_context's template decodes (field names as data); a review without one is left out")
    func decoding() throws {
        let byReview = try formats()
        #expect(byReview.count == 1)
        let proposal = try #require(byReview[reviewCode])
        #expect(proposal.templateCode == templateCode)
        #expect(proposal.bankCode == "FAB" && proposal.name == "FAB card purchase")
        #expect(proposal.fieldGroups == ["date": 5, "last4": 3, "amount": 2, "currency": 1, "merchant": 4])
        #expect(proposal.isFromAI && !proposal.active)
        #expect(proposal.title == "Proposed format: FAB card purchase")
        #expect(proposal.kindLabel == "Purchase")
        #expect(proposal.readsLabel ==
                "Reads currency (group 1), amount (group 2), last4 (group 3), merchant (group 4), date (group 5) · dates as DD/MM/YY")
        #expect(proposal.bodyPattern.hasPrefix("purchase of ([A-Z]{3})"))
    }

    @Test("a proposal offers Accept format and Reject only, as the web; Reject is the destructive one")
    func options() throws {
        let review = unparsed()
        let item = ReviewPresentation.item(review, inbox: ReviewInbox(reviews: [review], formats: try formats()))
        #expect(item.options.map(\.label) == ["Accept format", "Reject"])
        #expect(item.options.map(\.action) == [.decideFormat(templateCode: templateCode, accept: true),
                                               .decideFormat(templateCode: templateCode, accept: false)])
        #expect(item.options.map(\.isDestructive) == [false, true])
        #expect(item.proposal?.templateCode == templateCode)
        #expect(item.smsCode == review.subjectCode)
        #expect(item.bankCode == "FAB")          // the SMS has no bank yet: the proposal's
        #expect(item.note == nil)
    }

    @Test("Accept and Reject go to set_sms_template_active, not resolve_review, and are worded")
    func outcomes() {
        #expect(ReviewAction.decideFormat(templateCode: "tpl_1", accept: true).outcomeWithoutResolve == "format_accepted")
        #expect(ReviewAction.decideFormat(templateCode: "tpl_1", accept: false).outcomeWithoutResolve == "format_rejected")
        #expect(ReviewAction.decideFormat(templateCode: "tpl_1", accept: true).json == nil)
        #expect(ReviewAction.retryWithAI.outcomeWithoutResolve == "retrying")
        #expect(ReviewAction.dismiss.outcomeWithoutResolve == nil)
        #expect(ReviewPresentation.outcomeMessage("format_accepted") == "Format accepted. Waiting messages are being read again.")
        #expect(ReviewPresentation.outcomeMessage("format_rejected") == "Format rejected.")
        #expect(ReviewPresentation.help("unparsed_sms").contains("Accept a proposed format"))
    }

    @Test("42501 'not allowed' (a viewer, or already decided) becomes a sentence")
    func refused() {
        let text = ReviewPresentation.errorMessage(LedgerAPIError.server(status: nil, code: "42501", message: "not allowed"))
        #expect(text.contains("already decided") && text.contains("owner"))
    }

    @Test("the model accepts, says so and drops the review")
    @MainActor
    func accept() async throws {
        let api = StubAPI()
        let review = unparsed()
        api.inbox = ReviewInbox(reviews: [review], formats: try formats())
        let model = ReviewModel(api: api)
        await model.load(profileCode: "prf_a")
        let item = try #require(model.state.value?.first?.items.first)
        #expect(item.proposal != nil)

        api.inbox = ReviewInbox(reviews: [])   // the server closed it
        await model.resolve(item, item.options[0], profileCode: "prf_a")
        #expect(api.resolved.first?.1 == .decideFormat(templateCode: templateCode, accept: true))
        #expect(model.message == "Format accepted. Waiting messages are being read again.")
        #expect(model.isEmpty)
    }

    @Test("Show message reads the SMS text on request, hides it again, and forgets it on reset")
    @MainActor
    func showMessage() async {
        let api = StubAPI()
        api.smsBodies = ["sms_1": "Purchase of AED 12.00 with Credit Card ending 1234 at SHOP on 14/10/26"]
        let model = ReviewModel(api: api)
        #expect(model.messages.toggleLabel("sms_1") == "Show message")
        await model.messages.toggle("sms_1", profileCode: "prf_a")
        #expect(model.messages.open["sms_1"]?.value?.hasPrefix("Purchase of AED 12.00") == true)
        #expect(model.messages.toggleLabel("sms_1") == "Hide message")
        await model.messages.toggle("sms_1", profileCode: "prf_a")
        #expect(!model.messages.isOpen("sms_1"))
        await model.messages.toggle("sms_1", profileCode: "prf_a")
        model.reset()
        #expect(model.messages.open.isEmpty)
        #expect(api.smsBodyReads == ["sms_1", "sms_1"])
    }
}

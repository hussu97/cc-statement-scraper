import Foundation
import Testing
@testable import LedgerKit

@Suite("SMS go to — owned ledgers only")
struct SMSTargetTests {
    let personal = LedgerProfile(profileCode: "prf_personal", key: "personal", name: "Personal")
    let household = LedgerProfile(profileCode: "prf_house", key: "house", name: "Household")
    let viewed = LedgerProfile(profileCode: "prf_viewer", key: "viewer", name: "Brother's")

    func member(_ code: String, _ role: String) -> ProfileMembership {
        try! LedgerJSON.decode(ProfileMembership.self, from: Data(#"{"profile_code":"\#(code)","role":"\#(role)"}"#.utf8))
    }

    @Test("defaults to the first owned ledger, never a viewer one")
    func defaults() {
        let profiles = [viewed, household, personal]
        let members = [member("prf_viewer", "owner"), member("prf_house", "owner"), member("prf_personal", "owner")]
        #expect(SMSTarget.resolve(stored: nil, profiles: profiles, memberships: members)?.profileCode == "prf_viewer")
        let viewerOnly = [member("prf_viewer", "viewer"), member("prf_house", "owner")]
        #expect(SMSTarget.resolve(stored: nil, profiles: profiles, memberships: viewerOnly)?.profileCode == "prf_house")
        #expect(SMSTarget.eligible(profiles: profiles, memberships: viewerOnly).map(\.name) == ["Household"])
        #expect(SMSTarget.resolve(stored: nil, profiles: profiles, memberships: [member("prf_viewer", "viewer")]) == nil)
    }

    @Test("keeps a stored owned choice (with its current name); drops one the user no longer owns")
    func keepsChoice() {
        let profiles = [household, personal]
        let owner = [member("prf_house", "owner"), member("prf_personal", "owner")]
        let stored = SMSTarget(profileCode: "prf_personal", name: "Old name")
        #expect(SMSTarget.resolve(stored: stored, profiles: profiles, memberships: owner)
                == SMSTarget(profileCode: "prf_personal", name: "Personal"))
        let demoted = [member("prf_house", "owner"), member("prf_personal", "viewer")]
        #expect(SMSTarget.resolve(stored: stored, profiles: profiles, memberships: demoted)?.profileCode == "prf_house")
    }

    @Test("persists in the shared defaults the intent and the extension read")
    func store() throws {
        let defaults = try #require(UserDefaults(suiteName: "ledger-tests-\(UUID().uuidString)"))
        let store = SMSTargetStore(defaults: defaults)
        #expect(store.target == nil)
        store.target = SMSTarget(profileCode: "prf_personal", name: "Personal")
        #expect(SMSTargetStore(defaults: defaults).target?.name == "Personal")
        store.target = nil
        #expect(store.target == nil)
    }
}

@Suite("Sentry stays off locally")
struct TelemetryGateTests {
    let dsn = "https://key@o1.ingest.sentry.io/2"

    @Test func gate() {
        #expect(Telemetry.shouldStart(dsn: dsn, environment: "production", isDebugBuild: false))
        #expect(Telemetry.shouldStart(dsn: dsn, environment: "preview", isDebugBuild: false))
        for env in ["local", "development", "dev", "test", "LOCAL", " local ", nil] as [String?] {
            #expect(!Telemetry.shouldStart(dsn: dsn, environment: env, isDebugBuild: false), "env \(env ?? "nil")")
        }
        #expect(!Telemetry.shouldStart(dsn: dsn, environment: "production", isDebugBuild: true))
        #expect(!Telemetry.shouldStart(dsn: "", environment: "production", isDebugBuild: false))
        #expect(!Telemetry.shouldStart(dsn: nil, environment: "production", isDebugBuild: false))
    }
}

@Suite("Sign-in only counts when the session was saved")
struct SessionPersistenceTests {
    @Test func phases() {
        let saved = SessionStore.phase(signedInAs: "u1", email: "a@b.c", persistence: .saved)
        #expect(saved.phase == .signedIn(userID: "u1", email: "a@b.c"))
        #expect(saved.error == nil)
        #expect(SessionStore.phase(signedInAs: "u1", email: nil, persistence: .memoryOnly).phase
                == .signedIn(userID: "u1", email: nil))
        let failed = SessionStore.phase(signedInAs: "u1", email: nil, persistence: .failed(-34018))
        #expect(failed.phase == .signedOut)
        #expect(failed.error?.contains("-34018") == true)
    }

    @Test("Debug memory fallback keeps the session readable when the keychain refuses it")
    func memoryFallback() throws {
        // A service name no other test uses; on macOS the data-protection
        // keychain refuses an unsigned test binary, which is the case we want.
        let storage = SharedKeychainStorage(service: "ledger.tests.\(UUID().uuidString)",
                                            accessGroup: "NOTEAM.invalid.group", allowsMemoryFallback: true)
        let value = Data("session".utf8)
        try storage.store(key: "k", value: value)
        #expect(try storage.retrieve(key: "k") == value)
        if storage.persistenceFailure != nil {
            #expect(storage.isUsingMemoryFallback)
        }
        try storage.remove(key: "k")
        #expect(!storage.isUsingMemoryFallback)
    }
}

@Suite("Review — what the phone offers per review")
struct ReviewPresentationTests {
    func txn(_ code: String, merchant: String, amount: String) throws -> LedgerTransaction {
        let json = """
        {"txn_code":"\(code)","profile_code":"prf_a","account_code":"acc_a","status":"posted","kind":"purchase",
         "direction":"debit","txn_date":"2026-10-05","description":"\(merchant)","merchant_name":"\(merchant)",
         "amount_original":\(amount),"currency_original":"AED","amount_aed":\(amount),"bank_code":"FAB"}
        """
        return try LedgerJSON.decode(LedgerTransaction.self, from: Data(json.utf8))
    }

    @Test("unknown card: register to an account of the same bank, not a card transaction, or dismiss")
    func unknownCard() {
        let review = MatchReview(reviewCode: "rev_1", subjectType: "sms", subjectCode: "sms_1", reason: "unknown_card",
                                 candidates: [.init(txnCode: nil, bankCode: "ADCB", last4: "3687", templateCode: nil)])
        let inbox = ReviewInbox(
            reviews: [review],
            sms: ["sms_1": ReviewSMS(smsCode: "sms_1", bankCode: "ADCB", cardLast4: "3687", amount: Decimal(string: "46.00"),
                                     currency: "AED", merchantRaw: "VOX CINEMAS", receivedAt: Date(timeIntervalSince1970: 1_791_436_364))],
            accounts: [LedgerAccount(accountCode: "acc_fab", bankCode: "FAB", nickname: "FAB Cashback"),
                       LedgerAccount(accountCode: "acc_adcb", bankCode: "ADCB", productName: "Lulu Platinum")])
        let item = ReviewPresentation.item(review, inbox: inbox)
        #expect(item.subject == "ADCB •3687 · AED 46.00 · VOX CINEMAS")
        #expect(item.options.map(\.label) == ["Add •3687 to Lulu Platinum", "Not a card transaction", "Dismiss"])
        #expect(item.options[0].action == .registerCard(accountCode: "acc_adcb"))
        #expect(item.options[1].action == .notATransaction)
        #expect(item.options[2].isDestructive)
    }

    @Test("ambiguous SMS: link to each candidate, keep as new, or dismiss")
    func ambiguous() throws {
        let review = MatchReview(reviewCode: "rev_2", subjectType: "sms", subjectCode: "sms_2", reason: "ambiguous",
                                 candidates: [.init(txnCode: "txn_a", bankCode: nil, last4: nil, templateCode: nil),
                                              .init(txnCode: "txn_gone", bankCode: nil, last4: nil, templateCode: nil)])
        let inbox = ReviewInbox(reviews: [review], transactions: ["txn_a": try txn("txn_a", merchant: "Carrefour", amount: "45.10")])
        let item = ReviewPresentation.item(review, inbox: inbox)
        #expect(item.options.map(\.action) == [.link(txnCode: "txn_a"), .createNew, .dismiss])
        #expect(item.options[0].label.hasPrefix("Same as Carrefour · AED 45.10"))
    }

    @Test("reasons the phone can't resolve offer Dismiss and point to the web; groups follow the web's order")
    func otherReasons() {
        let overlap = MatchReview(reviewCode: "rev_3", subjectType: "statement", subjectCode: "stm_1", reason: "period_overlap")
        let unknown = MatchReview(reviewCode: "rev_4", subjectType: "sms", subjectCode: "sms_9", reason: "unknown_card")
        let item = ReviewPresentation.item(overlap, inbox: ReviewInbox(reviews: [overlap]))
        #expect(item.options.map(\.action) == [.dismiss])
        #expect(item.note != nil)
        let groups = ReviewPresentation.groups(ReviewInbox(reviews: [overlap, unknown]))
        #expect(groups.map(\.reason) == ["unknown_card", "period_overlap"])
        #expect(groups[0].title == "Unknown cards")
    }
}

@Suite("SMS setup guide — one automation on “Card”")
struct SMSGuideTests {
    /// Every credit-card purchase / refund / decline example in
    /// `supabase/migrations/20261008001000_sms_templates.sql` (one per format).
    static let realCardAlerts = [
        "Your Cr.Card XXX3687 was used for AED46.00 on 09/08/2026 13:43:40 at Vox Cinemas,Dubai-AE. Avl. Cr.limit is AED26953.75",
        "Credit Card XX3687 was used for EGP69.94 on 09/09/2026 11:44:55 at UBER *TRIP HELP.UBER, help.uber.com-NL. Available limit  AED19965.95",
        "Credit Card Purchase\nCard No XXXX2777\nAED 133.96\nAPPLE.COM/BILL CORK IRL\n05/10/26 09:12\nAvailable Balance AED 20000.00",
        "Purchase of AED 73.69 with Credit Card ending 7205 at Noon Minutes, Dubai. Avl Cr. Limit is AED 1,234.00",
        "Payment of AED 42.00 to Noon with Credit Card ending 7205. Avl Cr. Limit is AED 1,234.00",
        "Amount of AED 91.00 from NAMSHI has been credited to your card ending with 7205.",
        "A txn on your Covered Card XXXX5052 at Tesla Motors Netherlan for AED 52.91 on 02-10-2026 10:00 was approved",
    ]

    @Test("a single keyword, present in every real card alert (case-insensitively)")
    func oneKeyword() {
        #expect(SMSAutomationGuide.keywords == ["Card"])
        for body in Self.realCardAlerts {
            #expect(body.localizedCaseInsensitiveContains(SMSAutomationGuide.keywords[0]), "\(body.prefix(30))")
        }
    }

    @Test("the guide keeps Notify When Run on and has no 'repeat for other keywords' step")
    func guide() {
        let text = SMSAutomationGuide.steps.map { $0.title + " " + $0.detail }.joined(separator: "\n")
        #expect(text.contains("leave Notify When Run ON"))
        #expect(!text.contains("turn off Notify"))
        #expect(!text.contains("Repeat"))
        #expect(text.contains("Send test"))
    }

    @Test("step 5 in three pictures, each one in the app's asset catalog (IOS-06g)")
    func shortcutInputStrip() throws {
        let frames = SMSAutomationGuide.shortcutInputFrames
        #expect(frames.count == 3)
        #expect(frames.map { $0.caption.prefix(2) } == ["1.", "2.", "3."])
        #expect(frames.last?.caption.contains("Content") == true)
        // apps/ios/LedgerKit/Tests/LedgerKitTests/ → apps/ios/Ledger/Resources/Assets.xcassets
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../Ledger/Resources/Assets.xcassets").standardizedFileURL
        for frame in frames {
            let name = try #require(frame.image.split(separator: "/").last)
            let png = catalog.appending(path: "\(frame.image).imageset/\(name).png")
            #expect(FileManager.default.fileExists(atPath: png.path), "\(png.path)")
        }
        let step5 = try #require(SMSAutomationGuide.steps.first { $0.number == 5 })
        #expect(step5.detail.contains("Shortcut Input") && step5.detail.contains("Content"))
    }
}

#if canImport(SwiftUI)
import SwiftUI

@Suite("Dynamic Type — when rows stack")
struct DynamicTypeTests {
    @Test func stacking() {
        #expect(!DynamicTypeSize.large.prefersStackedRows)
        #expect(!DynamicTypeSize.xxLarge.prefersStackedRows)
        #expect(DynamicTypeSize.xxxLarge.prefersStackedRows)
        #expect(DynamicTypeSize.accessibility5.prefersStackedRows)
    }
}
#endif

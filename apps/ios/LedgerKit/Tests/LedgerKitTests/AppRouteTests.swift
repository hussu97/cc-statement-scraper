import Foundation
import Testing
@testable import LedgerKit

@Suite("App routing and the Share Extension's offline queue")
struct AppRouteTests {
    let p = LedgerProfile(profileCode: "prf_a", key: "a", name: "A")

    @Test func routes() {
        let signedIn = SessionStore.Phase.signedIn(userID: "u", email: nil)
        #expect(AppRoute.resolve(phase: .restoring, profiles: .idle, selected: nil) == .restoring)
        #expect(AppRoute.resolve(phase: .signedOut, profiles: .loaded([p]), selected: "prf_a") == .signIn)
        #expect(AppRoute.resolve(phase: .awaitingCode(email: "x@y.z"), profiles: .idle, selected: nil) == .signIn)
        #expect(AppRoute.resolve(phase: signedIn, profiles: .loading(previous: nil), selected: nil) == .loadingProfiles)
        #expect(AppRoute.resolve(phase: signedIn, profiles: .loaded([p]), selected: nil) == .pickProfile)
        #expect(AppRoute.resolve(phase: signedIn, profiles: .loaded([p]), selected: "prf_gone") == .pickProfile)
        #expect(AppRoute.resolve(phase: signedIn, profiles: .loaded([p]), selected: "prf_a") == .main(profileCode: "prf_a"))
        // A refresh keeps the main screen up rather than flashing the picker.
        #expect(AppRoute.resolve(phase: signedIn, profiles: .loading(previous: [p]), selected: "prf_a") == .main(profileCode: "prf_a"))
    }

    @Test("a stored session the server rejects is flagged so the app signs out, not stuck on the picker")
    @MainActor func rejectedSession() async {
        let api = StubAPI()
        let defaults = UserDefaults(suiteName: "ledger-route-\(UUID().uuidString)")!
        let store = ProfileStore(api: api, selection: ProfileSelection(defaults: defaults))
        api.profilesError = .notSignedIn
        await store.load()
        #expect(store.sessionRejected)
        api.profilesError = .network("offline")
        await store.load()
        #expect(!store.sessionRejected)
        api.profilesError = nil
        await store.load()
        #expect(!store.sessionRejected)
    }

    @Test("queued PDFs survive until uploaded, keep their names, and stop at the first failure")
    func pendingUploads() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-pending-\(UUID().uuidString)")
        let pending = PendingUploads(container: container)
        try pending.save(UploadFile(filename: "a.pdf", data: Data("%PDF-a".utf8)))
        try pending.save(UploadFile(filename: "a.pdf", data: Data("%PDF-b".utf8)))
        #expect(pending.count == 2)

        let names = NameLog()
        let failing = await pending.flush(profileCode: "prf_a") { _ in throw LedgerAPIError.network("x") }
        #expect(failing == 0)
        #expect(pending.count == 2)

        let sent = await pending.flush(profileCode: "prf_a") { file in
            names.append(file.filename)
            return UploadResponse(uploads: [.init(filename: file.filename, docCode: "doc_x", status: "queued")])
        }
        #expect(sent == 2)
        #expect(names.all == ["a.pdf", "a.pdf"])
        #expect(pending.count == 0)
    }
}

@MainActor
@Suite("Deep links: ledger://review, and Shortcut results that point to Review (IOS-07r)")
struct AppLinkTests {
    @Test("ledger://review parses in the shapes iOS hands over; other URLs are not ours", arguments: [
        ("ledger://review", true),
        ("LEDGER://Review", true),
        ("ledger://review/", true),
        ("ledger:///review", true),
        ("ledger://review?from=shortcut#x", true),
        ("ledger://settings", false),
        ("ledger://", false),
        ("https://cc-statement-scraper.vercel.app/review", false),
        ("ledgers://review", false),
    ])
    func parse(raw: String, isReview: Bool) throws {
        let url = try #require(URL(string: raw))
        #expect((AppLink(url: url) == .review) == isReview)
    }

    @Test func roundTrip() {
        #expect(AppLink.review.url.absoluteString == "ledger://review")
        #expect(AppLink.uncategorised.url.absoluteString == "ledger://uncategorised")
        #expect(AppLink.addStatement.url.absoluteString == "ledger://add-statement")
        for link in AppLink.allCases { #expect(AppLink(url: link.url) == link) }
        #expect(AppLink(url: URL(string: "LEDGER://Add-Statement/")!) == .addStatement)
        #expect(AppLink(url: URL(string: "ledger://uncategorized")!) == nil)
    }

    @Test("ledger://uncategorised opens Activity on this month's uncategorised rows, once")
    func uncategorised() {
        let router = TabRouter(today: { CalendarDay(year: 2026, month: 10, day: 13) })
        router.open(.uncategorised, ledgerOnScreen: true)
        #expect(router.tab == .activity && !router.showingReview)
        let preset = router.takeActivityPreset()
        #expect(preset == .uncategorised(month: CalendarDay(year: 2026, month: 10, day: 1)))
        #expect(preset?.uncategorizedOnly == true)
        #expect(preset?.from == CalendarDay(year: 2026, month: 10, day: 1))
        #expect(preset?.to == CalendarDay(year: 2026, month: 10, day: 31))
        #expect(router.takeActivityPreset() == nil)
    }

    @Test("ledger://add-statement pushes Statements and opens the picker once, for an owner only")
    func addStatement() {
        let router = TabRouter()
        router.open(.addStatement, ledgerOnScreen: true)
        #expect(router.tab == .settings && router.settingsPath == [.statements])
        #expect(router.takeAddStatementRequest(canUpload: true))
        #expect(!router.takeAddStatementRequest(canUpload: true))

        router.open(.addStatement, ledgerOnScreen: true)
        #expect(!router.takeAddStatementRequest(canUpload: false))   // a viewer: Statements, no picker
        #expect(!router.takeAddStatementRequest(canUpload: true))
    }

    @Test("a Control's intent hands its link to the app; one that came before the app's model waits")
    func inbox() {
        AppLinkInbox.detach()
        defer { AppLinkInbox.detach() }
        var opened: [AppLink] = []
        AppLinkInbox.deliver(.addStatement)          // cold launch: the intent ran first
        #expect(opened.isEmpty)
        AppLinkInbox.attach { opened.append($0) }
        #expect(opened == [.addStatement])
        AppLinkInbox.deliver(.uncategorised)
        #expect(opened == [.addStatement, .uncategorised])
    }

    @Test("a Control's link before a ledger is on screen waits through the ledger's reset")
    func controlLinkWaits() {
        let router = TabRouter()
        router.open(.addStatement, ledgerOnScreen: false)
        router.reset()
        #expect(router.settingsPath.isEmpty && router.pendingLink == .addStatement)
        router.ledgerShown()
        #expect(router.tab == .settings && router.settingsPath == [.statements])
        router.reset()   // another ledger: nothing pushed, nothing waiting
        #expect(router.settingsPath.isEmpty && !router.takeAddStatementRequest(canUpload: true))
    }

    @Test("Shortcut results link to Review only for what a review resolves")
    func outcomeLinks() {
        #expect(SMSIntakeOutcome.delivered(status: "unknown_card").link == .review)
        #expect(SMSIntakeOutcome.delivered(status: "held").link == .review)
        for status in ["new", "linked", "unparsed", "ignored", "duplicate_delivery", "already_linked", "rejected_otp"] {
            #expect(SMSIntakeOutcome.delivered(status: status).link == nil)
        }
        #expect(SMSIntakeOutcome.queued(.offline).link == nil)
        #expect(SMSIntakeOutcome.parked(reason: "x").link == nil)
        #expect(SMSIntakeOutcome.dropped(.dropOTP).link == nil)
        // A payment's unknown card is a card name to set in Settings, not a review.
        #expect(WalletIntake.link(.delivered(status: "unknown_card")) == nil)
        #expect(WalletIntake.link(.delivered(status: "held")) == .review)
        #expect(WalletIntake.link(.delivered(status: "new")) == nil)
    }

    @Test("the Shortcut line names Review exactly when a review is waiting; it never opens the app")
    func dialogPointsToReview() {
        let statuses = ["unknown_card", "held", "new", "unparsed", "ignored", "duplicate_delivery", "rejected_otp"]
        for status in statuses {
            let outcome = SMSIntakeOutcome.delivered(status: status)
            let line = outcome.dialog(ledger: "Home")
            #expect(line.hasSuffix(SMSIntakeOutcome.reviewPointer) == (outcome.link == .review), "\(status)")
            #expect(!line.contains("iPhone"))
        }
        #expect(SMSIntakeOutcome.delivered(status: "unknown_card").dialog(ledger: "Home")
                == "Logged to Home, but Ledger doesn't know this card yet. Needs a look in Review: open Ledger → Overview → Needs attention.")
        // A payment's unknown card points to Card names, not Review.
        let payment = WalletIntake.dialog(.delivered(status: "unknown_card"), ledger: "Home", card: "Wio")
        #expect(payment.contains("Card names") && !payment.contains("Review"))
        #expect(WalletIntake.dialog(.delivered(status: "held"), ledger: "Home", card: "Wio").hasSuffix(SMSIntakeOutcome.reviewPointer))
    }

    @Test("with a ledger on screen the link opens Overview → Review at once")
    func opensNow() {
        let router = TabRouter()
        router.show(.activity)
        router.open(.review, ledgerOnScreen: true)
        #expect(router.tab == .overview && router.showingReview && router.pendingLink == nil)
        router.reset()
        #expect(!router.showingReview)
    }

    @Test("before a ledger is on screen the link waits, survives the new ledger's reset, then opens once")
    func waits() {
        let router = TabRouter()
        router.open(.review, ledgerOnScreen: false)
        #expect(!router.showingReview && router.pendingLink == .review)
        router.reset()                      // profileSelected resets the tabs for the new ledger
        #expect(router.pendingLink == .review)
        router.ledgerShown()
        #expect(router.tab == .overview && router.showingReview && router.pendingLink == nil)
        router.showingReview = false        // back from Review
        router.ledgerShown()                // the next ledger switch opens nothing
        #expect(!router.showingReview)
    }

    @Test("signing out forgets a waiting link")
    func signOut() {
        let router = TabRouter()
        router.open(.review, ledgerOnScreen: false)
        router.signedOut()
        router.ledgerShown()
        #expect(!router.showingReview && router.pendingLink == nil)
    }

    @Test("a ledger is on screen only once the tabs point at the selected one")
    func onScreen() {
        #expect(AppModel.ledgerOnScreen(route: .main(profileCode: "prf_a"), activeProfile: "prf_a"))
        #expect(!AppModel.ledgerOnScreen(route: .main(profileCode: "prf_a"), activeProfile: nil))
        #expect(!AppModel.ledgerOnScreen(route: .main(profileCode: "prf_a"), activeProfile: "prf_b"))
        #expect(!AppModel.ledgerOnScreen(route: .signIn, activeProfile: "prf_a"))
        #expect(!AppModel.ledgerOnScreen(route: .restoring, activeProfile: nil))
        #expect(!AppModel.ledgerOnScreen(route: .pickProfile, activeProfile: "prf_a"))
    }
}

@Suite("Share Extension upload decisions")
struct ShareOutcomeTests {
    func pending() -> PendingUploads {
        PendingUploads(container: FileManager.default.temporaryDirectory.appendingPathComponent("ledger-share-\(UUID().uuidString)"))
    }
    let file = UploadFile(filename: "fab.pdf", data: Data("%PDF".utf8))

    @Test func uploaded() async {
        let outcome = await pending().share([file, file], profileCode: "prf_a") { f in
            UploadResponse(uploads: [.init(filename: f.filename, docCode: "doc_1", status: "queued")])
        }
        #expect(outcome == .uploaded(queued: 2, duplicates: 0))
        #expect(outcome.message == "Sent 2 PDFs: watch progress in Bank Ledger → Settings → Statements.")
    }

    @Test("offline or signed out: kept for the app to send")
    func offline() async {
        let p = pending()
        let outcome = await p.share([file], profileCode: "prf_a") { _ in throw LedgerAPIError.network("-1009") }
        #expect(outcome == .savedForLater(1))
        #expect(p.count == 1)
        let signedOut = await p.share([file], profileCode: "prf_a") { _ in throw LedgerAPIError.notSignedIn }
        #expect(signedOut == .savedForLater(1))
    }

    @Test("a permanent rejection is reported, not queued")
    func rejected() async {
        let p = pending()
        let outcome = await p.share([file], profileCode: "prf_a") { _ in
            throw LedgerAPIError.server(status: 422, code: "NOT_A_PDF", message: "fab.pdf is not a PDF")
        }
        #expect(outcome == .failed("fab.pdf is not a PDF"))
        #expect(p.count == 0)
    }

    @Test func noProfile() async {
        #expect(await pending().share([file], profileCode: nil) { _ in UploadResponse(uploads: []) } == .noProfile)
    }
}

final class NameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func append(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}

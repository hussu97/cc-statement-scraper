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
        #expect(outcome.message == "2 statements queued for parsing.")
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

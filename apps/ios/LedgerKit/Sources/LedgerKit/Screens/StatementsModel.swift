import Foundation
import Observation

/// Statements tab: statement cycles with recon chips, PDF upload, document status.
@MainActor
@Observable
public final class StatementsModel {
    public struct Content: Sendable {
        public let cycles: [StatementCycle]
        public let documents: [DocumentRecord]

        /// The newest statement (not history extract) of each account; every
        /// other cycle has been superseded by a newer statement.
        public var latestStatementCodes: Set<String> { StatementsModel.latestStatementCodes(cycles) }
    }

    /// Statement cycles, newest first, page after page.
    public let cycles = Paginator<StatementCycle>()
    /// Uploads, newest first, page after page.
    public let documents = Paginator<DocumentRecord>()
    /// The live per-file upload log (document picker).
    public let uploads: UploadSession
    /// A picked file that couldn't be read on the phone.
    public var uploadMessage: String?
    /// PDFs the Share Extension saved for later, and the ones the server refused.
    public private(set) var waitingLabel: String?
    public private(set) var rejected: [PendingUploads.Rejected] = []
    public private(set) var isSendingWaiting = false
    private let api: any LedgerAPI
    private var loadedProfile: String?
    private let pending: PendingUploads?
    private let flushPending: (@MainActor @Sendable () async -> Int)?

    /// - Parameters:
    ///   - pendingUploads: the Share Extension's queue in the App Group.
    ///   - flushPending: sends that queue to the "SMS go to" ledger (where the
    ///     extension filed it), not to the ledger on screen.
    public init(api: any LedgerAPI, pendingUploads: PendingUploads? = nil,
                flushPending: (@MainActor @Sendable () async -> Int)? = nil) {
        self.api = api
        self.pending = pendingUploads
        self.flushPending = flushPending
        self.uploads = UploadSession(api: api)
    }

    public var isUploading: Bool { uploads.isUploading }

    public var hasLoaded: Bool { loadedProfile != nil }

    /// The newest statement of each account among the loaded cycles (they load
    /// newest first, so page 1 already holds every account's newest).
    public var latestStatementCodes: Set<String> { Self.latestStatementCodes(cycles.items) }

    public func load(profileCode: String) async {
        let same = loadedProfile == profileCode
        loadedProfile = profileCode
        await refreshWaiting()
        let api = self.api
        async let a: Void = cycles.reload(keepingRows: same) { page in
            // `statement_cycles` takes a limit only: ask for everything up to
            // this page's end and keep the page's slice.
            let rows = try await api.statementCycles(profileCode: profileCode, limit: page.offset + page.limit)
            return ListPage(items: Array(rows.dropFirst(page.offset)), total: nil)
        }
        async let b: Void = documents.reload(keepingRows: same) { page in
            try await api.documents(profileCode: profileCode, page: page)
        }
        _ = await (a, b)
    }

    /// First visit of the tab for this ledger.
    public func loadIfNeeded(profileCode: String) async {
        guard loadedProfile != profileCode else { return }
        await load(profileCode: profileCode)
    }

    /// Realtime / foreground: the newest pages again, scrolled pages kept.
    public func refresh(profileCode: String) async {
        guard loadedProfile == profileCode else { return }
        await refreshWaiting()
        async let a: Void = cycles.refreshHead()
        async let b: Void = documents.refreshHead()
        _ = await (a, b)
    }

    public func reset() {
        cycles.reset()
        documents.reset()
        loadedProfile = nil
        uploadMessage = nil
        uploads.stop()
        uploads.clearFinished()
    }

    public nonisolated static func latestStatementCodes(_ cycles: [StatementCycle]) -> Set<String> {
        var newest: [String: StatementCycle] = [:]
        for cycle in cycles where cycle.kind == "statement" {
            if let current = newest[cycle.accountCode], current.statementDate >= cycle.statementDate { continue }
            newest[cycle.accountCode] = cycle
        }
        return Set(newest.values.map(\.stmtCode))
    }

    /// Reads the picked files (security-scoped URLs from the document picker)
    /// and uploads them one by one into the live log (BACKLOG IOS-17).
    public func upload(urls: [URL], profileCode: String) async {
        // Off the main thread: a picked iCloud Drive file may download while it is read.
        let (files, unreadable) = await Self.offMain { () -> ([UploadFile], [String]) in
            var files: [UploadFile] = []
            var unreadable: [String] = []
            for url in urls {
                if let file = try? Self.readFile(url) { files.append(file) } else { unreadable.append(url.lastPathComponent) }
            }
            return (files, unreadable)
        }
        uploadMessage = unreadable.isEmpty ? nil : "Couldn't read \(unreadable.joined(separator: ", "))."
        await uploads.upload(files, profileCode: profileCode)
        await refresh(profileCode: profileCode)
    }

    /// The detail screen for a statement row.
    public func detailModel(for cycle: StatementCycle) -> StatementDetailModel {
        StatementDetailModel(api: api, stmtCode: cycle.stmtCode, isLatest: latestStatementCodes.contains(cycle.stmtCode))
    }

    /// The full timeline of one document in the Uploads list.
    public func documentLog(for doc: DocumentRecord) -> DocumentLogModel {
        DocumentLogModel(api: api, document: doc)
    }

    // MARK: Share Extension queue (BACKLOG IOS-16r)

    /// Lists the App Group folder off the main thread (hang review, build 26).
    public func refreshWaiting() async {
        guard let pending else { return }
        let (label, refused) = await Self.offMain { (pending.waitingLabel, pending.rejected()) }
        waitingLabel = label
        rejected = refused
    }

    /// File I/O for the screen, on the cooperative pool instead of the main actor.
    @concurrent
    nonisolated static func offMain<T: Sendable>(_ work: @Sendable () -> T) async -> T { work() }

    /// Sends the waiting PDFs now (they also go when the app becomes active).
    public func sendWaiting(profileCode: String) async {
        guard let flushPending, !isSendingWaiting else { return }
        isSendingWaiting = true
        defer { isSendingWaiting = false }
        let sent = await flushPending()
        await refreshWaiting()
        if sent > 0 { await refresh(profileCode: profileCode) }
    }

    public func discard(_ item: PendingUploads.Rejected) async {
        guard let pending else { return }
        await Self.offMain { pending.discard(item) }
        await refreshWaiting()
    }

    public nonisolated static func readFile(_ url: URL) throws -> UploadFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return UploadFile(filename: url.lastPathComponent, data: try Data(contentsOf: url))
    }
}

extension StatementCycle {
    public var chips: [ReconChip] { ReconChip.chips(for: self) }
    /// Upcoming: `"Due in 5 days"`. Past: `"Was due 20 Sep"`. With the
    /// server's `payment_status`: `"Paid"`, `"Part paid (AED 1,200) · …"`,
    /// `"Overdue by 3 days"` — the same rule as Overview (`DueStatus`).
    public func due(isLatest: Bool, today: CalendarDay = LedgerDates.today()) -> (text: String, tone: Tone)? {
        DueStatus.describe(due: dueDate, isLatest: isLatest, payment: duePayment, today: today)
    }

    public var kindLabel: String { kind == "history_extract" ? "History extract" : "Statement" }

    /// `"1 Sep – 30 Sep"` when the period is known.
    public var periodLabel: String? {
        guard let start = periodStart, let end = periodEnd else { return nil }
        return "\(LedgerDates.dayLabel(start, today: end)) – \(LedgerDates.dayLabel(end, today: end))"
    }
}

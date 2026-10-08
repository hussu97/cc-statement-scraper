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
        public var latestStatementCodes: Set<String> {
            var newest: [String: StatementCycle] = [:]
            for cycle in cycles where cycle.kind == "statement" {
                if let current = newest[cycle.accountCode], current.statementDate >= cycle.statementDate { continue }
                newest[cycle.accountCode] = cycle
            }
            return Set(newest.values.map(\.stmtCode))
        }
    }

    public private(set) var state: LoadState<Content> = .idle
    /// The live per-file upload log (document picker).
    public let uploads: UploadSession
    /// PDFs the Share Extension saved for later, and the ones the server refused.
    public private(set) var waitingLabel: String?
    public private(set) var rejected: [PendingUploads.Rejected] = []
    public private(set) var isSendingWaiting = false
    /// A picked file that couldn't be read on the phone.
    public var uploadMessage: String?
    private let api: any LedgerAPI
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

    public func load(profileCode: String) async {
        state = state.startLoading()
        refreshWaiting()
        do {
            async let cycles = api.statementCycles(profileCode: profileCode, limit: 48)
            async let docs = api.documents(profileCode: profileCode, limit: 30)
            state = .loaded(try await Content(cycles: cycles, documents: docs))
        } catch {
            state = state.fail(error)
        }
    }

    /// Reads the picked files (security-scoped URLs from the document picker)
    /// and uploads them one by one into the live log.
    public func upload(urls: [URL], profileCode: String) async {
        var files: [UploadFile] = []
        var unreadable: [String] = []
        for url in urls {
            if let file = try? Self.readFile(url) { files.append(file) } else { unreadable.append(url.lastPathComponent) }
        }
        uploadMessage = unreadable.isEmpty ? nil : "Couldn't read \(unreadable.joined(separator: ", "))."
        await uploads.upload(files, profileCode: profileCode)
        await load(profileCode: profileCode)
    }

    /// The detail screen for a statement row.
    public func detailModel(for cycle: StatementCycle, isLatest: Bool) -> StatementDetailModel {
        StatementDetailModel(api: api, stmtCode: cycle.stmtCode, isLatest: isLatest)
    }

    /// The full timeline of one document in the Uploads list.
    public func documentLog(for doc: DocumentRecord) -> DocumentLogModel {
        DocumentLogModel(api: api, document: doc)
    }

    // MARK: Share Extension queue (IOS-16r)

    public func refreshWaiting() {
        waitingLabel = pending?.waitingLabel
        rejected = pending?.rejected() ?? []
    }

    /// Sends the waiting PDFs now (they also go when the app becomes active).
    public func sendWaiting(profileCode: String) async {
        guard let flushPending, !isSendingWaiting else { return }
        isSendingWaiting = true
        defer { isSendingWaiting = false }
        let sent = await flushPending()
        refreshWaiting()
        if sent > 0 { await load(profileCode: profileCode) }
    }

    public func discard(_ item: PendingUploads.Rejected) {
        pending?.discard(item)
        refreshWaiting()
    }

    public nonisolated static func readFile(_ url: URL) throws -> UploadFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return UploadFile(filename: url.lastPathComponent, data: try Data(contentsOf: url))
    }
}

extension StatementCycle {
    public var chips: [ReconChip] { ReconChip.chips(for: self) }
    /// Upcoming: `"Due in 5 days"`. Past: `"Was due 20 Sep"` — the same rule
    /// as Overview (`DueStatus`): payment isn't detected on the phone, so a
    /// statement is never called overdue.
    public func due(isLatest: Bool, today: CalendarDay = LedgerDates.today()) -> (text: String, tone: Tone)? {
        DueStatus.describe(due: dueDate, isLatest: isLatest, today: today)
    }

    public var kindLabel: String { kind == "history_extract" ? "History extract" : "Statement" }

    /// `"1 Sep – 30 Sep"` when the period is known.
    public var periodLabel: String? {
        guard let start = periodStart, let end = periodEnd else { return nil }
        return "\(LedgerDates.dayLabel(start, today: end)) – \(LedgerDates.dayLabel(end, today: end))"
    }
}

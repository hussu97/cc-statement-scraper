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
    public private(set) var isUploading = false
    public var uploadMessage: String?
    private let api: any LedgerAPI
    private var loadedProfile: String?

    public init(api: any LedgerAPI) { self.api = api }

    public var hasLoaded: Bool { loadedProfile != nil }

    /// The newest statement of each account among the loaded cycles (they load
    /// newest first, so page 1 already holds every account's newest).
    public var latestStatementCodes: Set<String> { Self.latestStatementCodes(cycles.items) }

    public func load(profileCode: String) async {
        let same = loadedProfile == profileCode
        loadedProfile = profileCode
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
        async let a: Void = cycles.refreshHead()
        async let b: Void = documents.refreshHead()
        _ = await (a, b)
    }

    public func reset() {
        cycles.reset()
        documents.reset()
        loadedProfile = nil
        uploadMessage = nil
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
    /// and uploads them in one request.
    public func upload(urls: [URL], profileCode: String) async {
        isUploading = true
        defer { isUploading = false }
        do {
            let files = try urls.map(Self.readFile)
            let response = try await api.uploadStatements(profileCode: profileCode, files: files)
            uploadMessage = response.summary
            await load(profileCode: profileCode)
        } catch {
            uploadMessage = LoadState<Int>.message(for: error)
        }
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

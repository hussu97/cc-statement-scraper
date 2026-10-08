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
    public private(set) var isUploading = false
    public var uploadMessage: String?
    private let api: any LedgerAPI

    public init(api: any LedgerAPI) { self.api = api }

    public func load(profileCode: String) async {
        state = state.startLoading()
        do {
            async let cycles = api.statementCycles(profileCode: profileCode, limit: 48)
            async let docs = api.documents(profileCode: profileCode, limit: 30)
            state = .loaded(try await Content(cycles: cycles, documents: docs))
        } catch {
            state = state.fail(error)
        }
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

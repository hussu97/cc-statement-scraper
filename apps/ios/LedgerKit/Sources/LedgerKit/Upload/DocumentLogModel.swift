import Foundation
import Observation

/// The full timeline of one document (a row in Statements → Uploads, which is
/// also where PDFs shared from another app show up): an initial fetch, then
/// Realtime rows while the sheet is open.
@MainActor
@Observable
public final class DocumentLogModel {
    public let document: DocumentRecord
    public private(set) var state: LoadState<[DocumentEvent]> = .idle
    private let api: any LedgerAPI
    private var listener: Task<Void, Never>?

    public init(api: any LedgerAPI, document: DocumentRecord) {
        self.api = api
        self.document = document
    }

    /// Newest attempt last; older attempts (re-uploads) stay above it.
    public var events: [DocumentEvent] { state.value ?? [] }

    /// The empty state: documents from before the timeline existed have none.
    public var emptyMessage: String? {
        guard case .loaded(let rows) = state, rows.isEmpty else { return nil }
        return "No processing log for this PDF. Uploads from before October 2026 don't have one."
    }

    /// What to do, when the document failed.
    public var advice: String? {
        if let failed = events.last(where: { $0.stage == "failed" }), events.last?.stage == "failed" {
            return UploadAdvice.forCode(failed.errorCode)
        }
        return UploadAdvice.forDocument(document)
    }

    public func start(profileCode: String) async {
        stop()
        let stream = api.documentEventStream(profileCode: profileCode)
        let docCode = document.docCode
        listener = Task { @MainActor [weak self] in
            for await event in stream where event.docCode == docCode {
                guard let self, !Task.isCancelled else { return }
                self.state = .loaded(DocumentEvent.merge(self.events, [event]))
            }
        }
        await load(profileCode: profileCode)
    }

    public func load(profileCode: String) async {
        state = state.startLoading()
        do {
            let rows = try await api.documentEvents(profileCode: profileCode, docCodes: [document.docCode])
            state = .loaded(DocumentEvent.merge(events, rows))
        } catch {
            state = state.fail(error)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

extension DocumentEvent {
    /// `"14:05"` (Dubai) for today's rows, `"8 Oct, 14:05"` otherwise.
    public func timeLabel(today: CalendarDay = LedgerDates.today()) -> String {
        let day = CalendarDay(date: createdAt)
        let time = LedgerDates.timeLabel(createdAt)
        return day == today ? time : "\(LedgerDates.dayLabel(day, today: today)), \(time)"
    }
}

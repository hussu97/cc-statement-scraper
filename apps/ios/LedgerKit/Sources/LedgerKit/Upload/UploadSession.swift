import Foundation
import Observation

/// One picked PDF on its way through upload, parse and import.
public struct UploadItem: Sendable, Hashable, Identifiable {
    public enum Phase: Sendable, Hashable {
        case waiting
        case uploading
        /// The server has it: `doc_code`, and whether it was already uploaded
        /// (`requeued`: a failed duplicate that is being read again).
        case sent(docCode: String, duplicate: Bool, requeued: Bool, parseStatus: String?)
        /// `statements-upload` refused it (too large, not a PDF, not an owner…).
        case rejected(String)
    }

    public let id: UUID
    public let filename: String
    public var phase: Phase

    public init(id: UUID = UUID(), filename: String, phase: Phase = .waiting) {
        self.id = id
        self.filename = filename
        self.phase = phase
    }

    public var docCode: String? {
        if case let .sent(code, _, _, _) = phase { return code }
        return nil
    }
}

/// The headline of an item: what happened last and what to do about it.
public struct UploadItemStatus: Sendable, Hashable {
    public let title: String
    public let detail: String?
    public let advice: String?
    public let tone: Tone
    public let systemImage: String
    public let isSettled: Bool
    public let inProgress: Bool

    /// - Parameter events: the document's timeline (any order, any attempt).
    public static func of(_ item: UploadItem, events: [DocumentEvent]) -> UploadItemStatus {
        switch item.phase {
        case .waiting:
            return .init(title: "Waiting to upload", detail: nil, advice: nil, tone: .neutral,
                         systemImage: "clock", isSettled: false, inProgress: false)
        case .uploading:
            return .init(title: "Uploading…", detail: nil, advice: nil, tone: .info,
                         systemImage: "arrow.up.circle", isSettled: false, inProgress: true)
        case .rejected(let message):
            return .init(title: "Not uploaded", detail: message, advice: nil, tone: .danger,
                         systemImage: "xmark.octagon.fill", isSettled: true, inProgress: false)
        case let .sent(_, duplicate, requeued, parseStatus):
            let attempt = DocumentEvent.latestAttempt(events)
            guard let last = attempt.last else {
                // No timeline (an older server, or the first rows not here yet).
                if duplicate && !requeued {
                    return .init(title: "Already in Bank Ledger", detail: parseStatus.map { "Status: \($0)" },
                                 advice: nil, tone: .info, systemImage: "doc.on.doc", isSettled: true, inProgress: false)
                }
                return .init(title: "Sent", detail: "Waiting for the first update…", advice: nil, tone: .info,
                             systemImage: "paperplane", isSettled: false, inProgress: true)
            }
            let stage = StagePresentation.of(last)
            let settled: Bool = switch last.stage {
            case "ingested", "failed": true
            case "duplicate": !requeued && parseStatus != "queued" && parseStatus != "parsing"
            default: false
            }
            let advice = last.stage == "failed" ? UploadAdvice.forCode(last.errorCode) : nil
            return .init(title: stage.label, detail: last.message.isEmpty ? nil : last.message, advice: advice,
                         tone: stage.tone, systemImage: stage.systemImage, isSettled: settled, inProgress: !settled)
        }
    }
}

/// The live upload log on Statements. Files go up one request each, so one
/// bad PDF can't reject the rest; `document_events` (Realtime, plus a fetch
/// after each upload and a slow poll in case Realtime is down) move each row
/// from "Uploading…" to "Imported" or to the failure and what to do.
@MainActor
@Observable
public final class UploadSession {
    public private(set) var items: [UploadItem] = []
    /// Timelines by `doc_code`. Filled before the upload answers: `received`
    /// and `stored` arrive while the request is still open.
    public private(set) var events: [String: [DocumentEvent]] = [:]

    private let api: any LedgerAPI
    private let pollInterval: Duration
    private let pollLimit: Int
    private var listener: Task<Void, Never>?
    private var poller: Task<Void, Never>?

    public init(api: any LedgerAPI, pollInterval: Duration = .seconds(4), pollLimit: Int = 60) {
        self.api = api
        self.pollInterval = pollInterval
        self.pollLimit = pollLimit
    }

    public var isEmpty: Bool { items.isEmpty }
    public var isUploading: Bool { items.contains { $0.phase == .uploading || $0.phase == .waiting } }
    /// Anything still moving (uploading, queued, being read).
    public var isActive: Bool { items.contains { !status(of: $0).isSettled } }

    public func status(of item: UploadItem) -> UploadItemStatus {
        UploadItemStatus.of(item, events: item.docCode.flatMap { events[$0] } ?? [])
    }

    /// The rows under an item: its latest attempt, oldest first.
    public func timeline(of item: UploadItem) -> [DocumentEvent] {
        DocumentEvent.latestAttempt(item.docCode.flatMap { events[$0] } ?? [])
    }

    /// `"2 of 3 imported · 1 failed"`.
    public var summary: String? {
        guard !items.isEmpty else { return nil }
        let statuses = items.map(status(of:))
        let done = statuses.filter { $0.isSettled && $0.tone != .danger }.count
        let failed = statuses.filter { $0.tone == .danger }.count
        var parts = ["\(done) of \(items.count) done"]
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    /// Uploads each file on its own, following its events live.
    public func upload(_ files: [UploadFile], profileCode: String) async {
        let new = files.map { UploadItem(filename: $0.filename) }
        items.append(contentsOf: new)
        listen(profileCode: profileCode)
        for (item, file) in zip(new, files) {
            setPhase(item.id, .uploading)
            do {
                let response = try await api.uploadStatements(profileCode: profileCode, files: [file])
                guard let result = response.uploads.first else {
                    setPhase(item.id, .rejected("The server didn't answer for this file."))
                    continue
                }
                setPhase(item.id, .sent(docCode: result.docCode, duplicate: result.status == "duplicate",
                                        requeued: result.requeued, parseStatus: result.parseStatus))
                await fetch(profileCode: profileCode, docCodes: [result.docCode])
            } catch {
                setPhase(item.id, .rejected(LoadState<Int>.message(for: error)))
            }
        }
        startPolling(profileCode: profileCode)
    }

    /// Adds Realtime rows (any document of the profile; only tracked ones show).
    public func apply(_ incoming: [DocumentEvent]) {
        for (doc, rows) in Dictionary(grouping: incoming, by: \.docCode) {
            events[doc] = DocumentEvent.merge(events[doc] ?? [], rows)
        }
        if !isActive { stop() }
    }

    /// Forgets finished rows (the "Clear" button); keeps anything still moving.
    public func clearFinished() {
        items.removeAll { status(of: $0).isSettled }
        let tracked = Set(items.compactMap(\.docCode))
        events = events.filter { tracked.contains($0.key) }
        if items.isEmpty { stop() }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        poller?.cancel()
        poller = nil
    }

    // MARK: Plumbing

    private func setPhase(_ id: UUID, _ phase: UploadItem.Phase) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].phase = phase
    }

    private func fetch(profileCode: String, docCodes: [String]) async {
        guard !docCodes.isEmpty, let rows = try? await api.documentEvents(profileCode: profileCode, docCodes: docCodes) else { return }
        apply(rows)
    }

    private func listen(profileCode: String) {
        guard listener == nil else { return }
        let stream = api.documentEventStream(profileCode: profileCode)
        listener = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.apply([event])
            }
        }
    }

    /// A fallback for a missed Realtime row: refetch unsettled documents.
    private func startPolling(profileCode: String) {
        guard poller == nil, isActive else { return }
        let interval = pollInterval
        let limit = pollLimit
        poller = Task { @MainActor [weak self] in
            for _ in 0..<limit {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.isActive else { return }
                let open = self.items.filter { !self.status(of: $0).isSettled }.compactMap(\.docCode)
                await self.fetch(profileCode: profileCode, docCodes: open)
            }
        }
    }
}

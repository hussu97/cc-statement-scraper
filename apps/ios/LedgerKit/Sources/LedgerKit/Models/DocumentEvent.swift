import Foundation

/// One row of `public.document_events`: a step in a PDF's upload → parse →
/// import timeline. Messages are written for people by the server; `detail`
/// carries codes and counts only (a failure's `error_code`).
public struct DocumentEvent: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { eventCode }
    public let eventCode: String
    public let profileCode: String
    public let docCode: String
    public let createdAt: Date
    /// received | stored | duplicate | queued | parsing | parsed | ingested | failed | retry
    public let stage: String
    /// info | warn | error
    public let level: String
    public let message: String
    /// `detail.error_code` on `failed` and `retry`.
    public let errorCode: String?

    enum CodingKeys: String, CodingKey { case eventCode, profileCode, docCode, createdAt, stage, level, message, detail }
    struct Detail: Decodable { let errorCode: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventCode = try c.decode(String.self, forKey: .eventCode)
        profileCode = try c.decode(String.self, forKey: .profileCode)
        docCode = try c.decode(String.self, forKey: .docCode)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        stage = try c.decode(String.self, forKey: .stage)
        level = (try? c.decodeIfPresent(String.self, forKey: .level)) ?? "info"
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        errorCode = ((try? c.decodeIfPresent(Detail.self, forKey: .detail)) ?? nil)?.errorCode
    }

    public init(eventCode: String, profileCode: String = "prf_x", docCode: String, createdAt: Date, stage: String,
                level: String = "info", message: String = "", errorCode: String? = nil) {
        self.eventCode = eventCode
        self.profileCode = profileCode
        self.docCode = docCode
        self.createdAt = createdAt
        self.stage = stage
        self.level = level
        self.message = message
        self.errorCode = errorCode
    }

    /// Server order: `created_at`, then `event_code` (ULIDs sort by time).
    public static func ordered(_ events: [DocumentEvent]) -> [DocumentEvent] {
        events.sorted { ($0.createdAt, $0.eventCode) < ($1.createdAt, $1.eventCode) }
    }

    /// Merges new rows into a timeline: no duplicates (Realtime and the
    /// initial fetch overlap), server order.
    public static func merge(_ existing: [DocumentEvent], _ incoming: [DocumentEvent]) -> [DocumentEvent] {
        var byCode = Dictionary(existing.map { ($0.eventCode, $0) }, uniquingKeysWith: { a, _ in a })
        for e in incoming { byCode[e.eventCode] = e }
        return ordered(Array(byCode.values))
    }

    /// The events of the latest upload of a document: everything from its last
    /// `received` on (a duplicate upload re-uses an old document's code).
    public static func latestAttempt(_ events: [DocumentEvent]) -> [DocumentEvent] {
        let sorted = ordered(events)
        guard let start = sorted.lastIndex(where: { $0.stage == "received" }) else { return sorted }
        return Array(sorted[start...])
    }
}

/// How the timeline draws a stage.
public struct StagePresentation: Sendable, Hashable {
    public let label: String
    public let systemImage: String
    public let tone: Tone

    public static func of(_ event: DocumentEvent) -> StagePresentation {
        let base: (String, String) = switch event.stage {
        case "received": ("Received", "tray.and.arrow.down")
        case "stored": ("Saved", "externaldrive")
        case "duplicate": ("Already uploaded", "doc.on.doc")
        case "queued": ("Waiting", "clock")
        case "parsing": ("Reading", "doc.text.magnifyingglass")
        case "parsed": ("Read", "doc.text")
        case "ingested": ("Imported", "checkmark.circle.fill")
        case "failed": ("Failed", "exclamationmark.triangle.fill")
        case "retry": ("Retrying", "arrow.clockwise")
        default: (event.stage.capitalized, "circle")
        }
        let tone: Tone = switch event.level {
        case "error": .danger
        case "warn": .warn
        default: event.stage == "ingested" ? .positive : .neutral
        }
        return StagePresentation(label: base.0, systemImage: base.1, tone: tone)
    }
}

/// What the person can do about a failed statement, by error code (parse-v1
/// codes, worker codes, `INGEST_<sqlstate>`). The server's message says what
/// happened; this says what to do next.
public enum UploadAdvice {
    public static func forCode(_ code: String?) -> String? {
        guard let code else { return nil }
        switch code {
        case "PDF_DECRYPT_FAILED":
            return "Set the password on the web: Settings → Statement passwords. Then upload the PDF again."
        case "BANK_UNDETECTED":
            return "Upload it on the web and choose the bank."
        case "UNSUPPORTED_BANK", "UNSUPPORTED_LAYOUT":
            return "Nothing to fix on your side. SMS alerts for this card still count."
        case "PDF_TOO_LARGE", "PARSE_TIMEOUT":
            return "Try the bank's monthly e-statement instead of a long export."
        case "DOWNLOAD_FAILED", "DOCUMENT_MISSING":
            return "Upload the PDF again."
        case "MAX_ATTEMPTS":
            return "Upload it again later. If it keeps failing, check Uploads on the web."
        case let c where c == "PARSE_OUTPUT_INVALID" || c.hasPrefix("INGEST_"):
            return "Upload it again after the next app update, or check it on the web."
        default:
            return nil
        }
    }

    /// A `documents` row's failure (`parse_error_code`), for the Uploads list.
    public static func forDocument(_ doc: DocumentRecord) -> String? {
        doc.parseStatus == "failed" ? forCode(doc.parseErrorCode) : nil
    }
}

extension DocumentRecord {
    /// `parse_error` is the raw parser text; only its first sentence is shown,
    /// and only for a failed document.
    public var failureDetail: String? {
        guard parseStatus == "failed", let parseError, !parseError.isEmpty else { return nil }
        let line = parseError.split(whereSeparator: \.isNewline).first.map(String.init) ?? parseError
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}

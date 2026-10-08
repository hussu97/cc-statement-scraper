import Foundation

/// `public.profiles` — one financial ledger. Named to stay clear of any
/// framework `Profile` type.
public struct LedgerProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String { profileCode }
    public let profileCode: String
    public let key: String
    public let name: String
    public let baseCurrency: String

    public init(profileCode: String, key: String, name: String, baseCurrency: String = "AED") {
        self.profileCode = profileCode
        self.key = key
        self.name = name
        self.baseCurrency = baseCurrency
    }
}

/// `public.profile_members` for the signed-in user.
public struct ProfileMembership: Decodable, Sendable, Hashable {
    public let profileCode: String
    public let role: String           // owner | viewer
    public var isOwner: Bool { role == "owner" }
}

/// `public.insights`.
public struct Insight: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { insightCode }
    public let insightCode: String
    public let kind: String
    public let severity: String       // info | warn | alert
    public let title: String
    public let body: String
    public let validUntil: CalendarDay?
    public let dismissedAt: Date?
    public let createdAt: Date
}

/// `public.documents` — a PDF as received, and where its parse is.
public struct DocumentRecord: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { docCode }
    public let docCode: String
    public let kind: String?
    public let bankCode: String?
    public let originalFilename: String
    public let source: String
    public let parseStatus: String    // queued | parsing | parsed | failed
    public let parseErrorCode: String?
    public let parseError: String?
    public let createdAt: Date
    public let parsedAt: Date?

    public var statusLabel: String {
        switch parseStatus {
        case "queued": "Queued"
        case "parsing": "Parsing"
        case "parsed": "Parsed"
        case "failed": parseErrorCode.map { "Failed · \($0)" } ?? "Failed"
        default: parseStatus.capitalized
        }
    }
}

/// One entry of `ingest_sms`'s per-message result array.
public struct SMSIngestResult: Decodable, Sendable, Hashable {
    public let clientMsgId: String
    public let smsCode: String?
    /// created/linked/duplicate/held/skipped from the matcher, or `unparsed`,
    /// `ignored`, `unknown_card`, `rejected_otp`, `duplicate_delivery`,
    /// `already_linked`; newer servers answer `invalid` (not stored; `reason`
    /// says why) for a message they refuse, and `failed` (stored, but
    /// processing raised; `reason` = `error:<sqlstate>`) instead of failing
    /// the whole batch. Both are terminal: the outbox parks them, never retries.
    public let status: String
    public let txnCode: String?
    /// Why a message was refused (`invalid` / `failed`). Absent on older servers.
    public let reason: String?

    public init(clientMsgId: String, smsCode: String?, status: String, txnCode: String?, reason: String? = nil) {
        self.clientMsgId = clientMsgId
        self.smsCode = smsCode
        self.status = status
        self.txnCode = txnCode
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case clientMsgId, smsCode, status, txnCode, reason }

    /// Lenient on the optional fields so a newer server's extra shapes never
    /// make a whole batch's answer unreadable.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientMsgId = (try? c.decodeIfPresent(String.self, forKey: .clientMsgId)) ?? ""
        smsCode = (try? c.decodeIfPresent(String.self, forKey: .smsCode)) ?? nil
        status = try c.decode(String.self, forKey: .status)
        txnCode = (try? c.decodeIfPresent(String.self, forKey: .txnCode)) ?? nil
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
    }

    /// Per-message statuses that mean the server did not take the message.
    /// Everything else is final and needs no retry.
    public static let failureStatuses: Set<String> = ["invalid", "error", "failed", "rejected"]

    public var isFailure: Bool { Self.failureStatuses.contains(status) }

    /// Shown in Settings → Not sent next to a parked message.
    public var failureReason: String {
        if status == "failed" {
            let code = reason.flatMap { $0.hasPrefix("error:") ? String($0.dropFirst(6)) : nil }
            let detail = code.map { $0.isEmpty ? "" : " (error \($0))" } ?? ""
            return "Ledger saved this message but couldn't process it\(detail). It tries again when SMS formats change."
        }
        if let reason, !reason.isEmpty {
            if let sentence = Self.invalidReasons[reason] { return "Ledger rejected this message: \(sentence)" }
            return "Ledger rejected this message: \(reason)"
        }
        return "Ledger rejected this message (\(status))."
    }

    /// `ingest_sms`'s `invalid` reasons (`private.sms_input_problem`), in words.
    static let invalidReasons: [String: String] = [
        "not_an_object": "it wasn't sent in the expected format.",
        "invalid_client_msg_id": "its message ID isn't valid.",
        "missing_body": "it has no text.",
        "body_too_long": "it's longer than 2,000 characters.",
        "invalid_sender": "its sender isn't valid.",
        "invalid_received_at": "its received time isn't valid.",
    ]
}

/// Response of the `statements-upload` Edge Function:
/// `{"uploads": [{"filename", "doc_code", "status": "queued"|"duplicate", "parse_status", "requeued"?}]}`.
/// `requeued`: a duplicate of a document whose parse failed, queued again.
public struct UploadResponse: Decodable, Sendable, Hashable {
    public struct Item: Decodable, Sendable, Hashable {
        public let filename: String
        public let docCode: String
        public let status: String
        public let parseStatus: String?
        public let requeued: Bool

        public init(filename: String, docCode: String, status: String, parseStatus: String? = nil, requeued: Bool = false) {
            self.filename = filename
            self.docCode = docCode
            self.status = status
            self.parseStatus = parseStatus
            self.requeued = requeued
        }

        enum CodingKeys: String, CodingKey { case filename, docCode, status, parseStatus, requeued }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            filename = try c.decode(String.self, forKey: .filename)
            docCode = try c.decode(String.self, forKey: .docCode)
            status = try c.decode(String.self, forKey: .status)
            parseStatus = (try? c.decodeIfPresent(String.self, forKey: .parseStatus)) ?? nil
            requeued = (try? c.decodeIfPresent(Bool.self, forKey: .requeued)) ?? false
        }
    }
    public let uploads: [Item]

    public init(uploads: [Item]) { self.uploads = uploads }

    /// `"1 queued"`, `"2 queued, 1 already uploaded"`.
    public var summary: String {
        let queued = uploads.filter { $0.status == "queued" }.count
        let dup = uploads.count - queued
        var parts: [String] = []
        if queued > 0 { parts.append("\(queued) queued") }
        if dup > 0 { parts.append("\(dup) already uploaded") }
        return parts.isEmpty ? "Nothing uploaded" : parts.joined(separator: ", ")
    }
}

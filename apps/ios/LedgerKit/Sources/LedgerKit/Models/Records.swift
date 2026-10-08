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
    /// parsed/linked/new/review statuses from the matcher, or `unparsed`,
    /// `ignored`, `unknown_card`, `rejected_otp`, `duplicate_delivery`, `already_linked`.
    public let status: String
    public let txnCode: String?
}

/// Response of the `statements-upload` Edge Function:
/// `{"uploads": [{"filename", "doc_code", "status": "queued"|"duplicate"}]}`.
public struct UploadResponse: Decodable, Sendable, Hashable {
    public struct Item: Decodable, Sendable, Hashable {
        public let filename: String
        public let docCode: String
        public let status: String

        public init(filename: String, docCode: String, status: String) {
            self.filename = filename
            self.docCode = docCode
            self.status = status
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

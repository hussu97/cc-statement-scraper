import Foundation

/// A file kept with a holding (`20261108112842_holding_attachments.sql`): an invoice photo or PDF,
/// a certificate. One entry of `holding_detail.attachments`, newest first. The object lives in the
/// private `holding-attachments` bucket at `storage_path` (`<profile>/<holding>/<file>`); type and
/// size are what Storage recorded, not what the phone said.
public struct HoldingAttachment: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { attachmentCode }
    /// `hat_…`.
    public let attachmentCode: String
    public let storagePath: String
    public let fileName: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let caption: String?
    public let createdAt: Date

    public init(attachmentCode: String, storagePath: String, fileName: String, mimeType: String, sizeBytes: Int64,
                caption: String? = nil, createdAt: Date) {
        self.attachmentCode = attachmentCode
        self.storagePath = storagePath
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.caption = caption
        self.createdAt = createdAt
    }

    /// What a row shows: its caption, else its file name.
    public var label: String {
        let c = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return c.isEmpty ? fileName : c
    }

    public var isImage: Bool { HoldingAttachments.isImage(mimeType) }
    public var isPDF: Bool { HoldingAttachments.isPDF(mimeType) }

    /// `"2.3 MB"`.
    public var sizeText: String { HoldingAttachments.formatBytes(sizeBytes) }

    /// The Dubai day it was added: `"8 Nov 2026"`.
    public var addedText: String { LedgerDates.fullDayLabel(CalendarDay(date: createdAt)) }

    /// A row's second line: `"8 Nov 2026 · 2.3 MB"`, as the web's tile says it.
    public var detailText: String { "\(addedText) · \(sizeText)" }

    /// The row's icon: a PDF or a photo.
    public var systemImage: String { isPDF ? "doc.richtext" : "photo" }
}

/// What `uploadHoldingAttachment` sends: the bytes go to `storagePath` in the bucket, then
/// `add_holding_attachment` records them.
public struct HoldingAttachmentUpload: Sendable, Hashable {
    public let holdingCode: String
    public let storagePath: String
    public let fileName: String
    public let mimeType: String
    public let data: Data
    public let caption: String?

    public init(holdingCode: String, storagePath: String, fileName: String, mimeType: String, data: Data,
                caption: String? = nil) {
        self.holdingCode = holdingCode
        self.storagePath = storagePath
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
        self.caption = caption
    }
}

/// The rules the bucket and `add_holding_attachment` enforce, checked on the phone first so a
/// refusal reads plainly (the web's `lib/holding-attachments.ts`, word for word where it can be).
/// The server checks everything again.
public enum HoldingAttachments {
    /// The private bucket (migration `20261108112842_holding_attachments`).
    public static let bucket = "holding-attachments"
    /// `storage.buckets.file_size_limit`: 10 MB.
    public static let maxBytes = 10 * 1024 * 1024
    /// `add_holding_attachment` refuses more than this per holding.
    public static let maxCount = 20
    /// A photo is sent as JPEG at this quality (`UIImage.jpegData(compressionQuality:)`).
    public static let photoQuality = 0.85
    /// A photo's longer side is scaled down to this many pixels before it is encoded, so a 48 MP
    /// photo stays well under the size limit and an invoice stays readable.
    public static let photoMaxSide = 4096.0

    /// The bucket's allowed types and the extension each is stored under.
    public static let types: [String: String] = [
        "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic", "application/pdf": "pdf",
    ]
    private static let extensionTypes: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp", "heic": "image/heic",
        "pdf": "application/pdf",
    ]

    public static func isImage(_ mimeType: String) -> Bool { mimeType.hasPrefix("image/") }
    public static func isPDF(_ mimeType: String) -> Bool { mimeType == "application/pdf" }

    /// A picked file's type from its extension; nil for anything the bucket refuses.
    public static func mimeType(forFileName name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return extensionTypes[name[name.index(after: dot)...].lowercased()]
    }

    /// Where a new file goes: `<profile>/<holding>/<id>.<ext>`, the only shape
    /// `add_holding_attachment` accepts. Nil for a type the bucket refuses.
    public static func storagePath(profileCode: String, holdingCode: String, id: UUID, mimeType: String) -> String? {
        guard let ext = types[mimeType], !profileCode.isEmpty, !holdingCode.isEmpty else { return nil }
        return "\(profileCode)/\(holdingCode)/\(id.uuidString.lowercased()).\(ext)"
    }

    /// `512` → `"512 B"`, `81920` → `"80 KB"`, `2400000` → `"2.3 MB"` (1024-based, as the web).
    public static func formatBytes(_ bytes: Int64) -> String {
        guard bytes >= 0 else { return "" }
        if bytes < 1024 { return "\(bytes) B" }
        let mib: Int64 = 1024 * 1024
        if bytes < mib { return "\((bytes + 512) / 1024) KB" }
        let tenths = (bytes * 10 + mib / 2) / mib
        return "\(tenths / 10).\(tenths % 10) MB"
    }

    /// The phone's checks before an upload, in the web's order: type, empty, size, room left.
    /// Nil when the file may go.
    public static func check(byteCount: Int, mimeType: String?, existing: Int) -> String? {
        guard let mimeType, types[mimeType] != nil else { return unsupportedType }
        if byteCount <= 0 { return "The file is empty." }
        if byteCount > maxBytes { return "Files are at most 10 MB." }
        if existing >= maxCount { return fullMessage }
        return nil
    }

    public static let unsupportedType = "Only photos (JPEG, PNG, WebP, HEIC) and PDFs can be added."
    public static let unreadablePhoto = "Couldn't read the photo. Try another."
    public static let fullMessage = "A holding keeps at most 20 files. Remove one to add another."

    /// A photo from the library has no name of its own: `"Photo 8 Nov 2026.jpg"`.
    public static func photoFileName(on day: CalendarDay) -> String { "Photo \(LedgerDates.fullDayLabel(day)).jpg" }

    /// The name a file is recorded under: trimmed, no path separators, at most 200 characters
    /// (the column's limit), and something when it was empty.
    public static func cleanFileName(_ name: String, mimeType: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if n.isEmpty { n = (isPDF(mimeType) ? "File" : "Photo") + "." + (types[mimeType] ?? "jpg") }
        return String(n.prefix(200))
    }

    /// What a shared copy is called: the recorded name, ending in its type's extension.
    public static func shareFilename(_ attachment: HoldingAttachment) -> String {
        let name = cleanFileName(attachment.fileName, mimeType: attachment.mimeType)
        guard let ext = types[attachment.mimeType] else { return name }
        let lower = name.lowercased()
        let known = extensionTypes.filter { $0.value == attachment.mimeType }.map { "." + $0.key }
        return known.contains(where: { lower.hasSuffix($0) }) ? name : name + "." + ext
    }

    /// A photo's size after scaling its longer side down to `photoMaxSide` (never up).
    public static func photoSize(width: Double, height: Double) -> (width: Double, height: Double) {
        let longer = max(width, height)
        guard longer > photoMaxSide, longer > 0 else { return (width, height) }
        let scale = photoMaxSide / longer
        return ((width * scale).rounded(), (height * scale).rounded())
    }

    /// Whether downloaded bytes are a picture the bucket takes (JPEG, PNG, WebP, HEIC), not an
    /// error page or an empty body.
    public static func isImageData(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return false }
        if Array(b[0..<3]) == [0xFF, 0xD8, 0xFF] { return true }                     // JPEG
        if Array(b[0..<4]) == [0x89, 0x50, 0x4E, 0x47] { return true }               // PNG
        guard b.count >= 12 else { return false }
        if Array(b[0..<4]) == [0x52, 0x49, 0x46, 0x46], Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return true                                                               // RIFF…WEBP
        }
        return Array(b[4..<8]) == [0x66, 0x74, 0x79, 0x70]                           // HEIC: …ftyp
    }

    // MARK: Removing

    public static func removeTitle(_ attachment: HoldingAttachment) -> String { "Remove \(attachment.label)?" }
    public static let removeMessage = "The file is deleted for everyone who can see this ledger."

    // MARK: Failures

    public enum Failure: Error, Equatable {
        /// Storage refused (its message).
        case storage(String)
        /// What came back isn't the photo or PDF it should be.
        case unreadable
    }

    /// Storage's words for a refused upload or a missing object, said plainly.
    public static func storageMessage(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("not found") || lower.contains("notfound") || lower.contains("not_found") {
            return "The file isn't in storage."
        }
        if lower.contains("exceeded") || lower.contains("too large") || lower.contains("size") {
            return "Files are at most 10 MB."
        }
        if lower.contains("mime") { return unsupportedType }
        return message.isEmpty ? "Couldn't reach the file." : message
    }

    /// An add or remove that failed, in plain words (the web's `holdingErrorMessage`).
    public static func message(for error: any Error) -> String {
        if error is Failure || error is StatementPDF.Failure { return openMessage(for: error) }
        guard let api = error as? LedgerAPIError, case let .server(_, code, message) = api else {
            return LoadState<Bool>.message(for: error)
        }
        if api.isPermission { return HoldingDraft.ownerOnlyMessage }
        switch code {
        case "P0002":
            let lower = message.lowercased()
            if lower.contains("attachment") { return "That file was already removed." }
            if lower.contains("uploaded") { return "The file didn't finish uploading. Try again." }
            return "This holding isn't in the ledger any more, or it was closed. Pull to refresh."
        case "22023":
            guard let first = message.first else { return "Check the file and try again." }
            return first.uppercased() + String(message.dropFirst()) + "."
        default:
            return LoadState<Bool>.message(for: error)
        }
    }

    /// Opening a file that failed.
    public static func openMessage(for error: any Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .storage(let m): return storageMessage(m)
            case .unreadable: return "Couldn't open the file."
            }
        }
        if let failure = error as? StatementPDF.Failure {
            switch failure {
            case .storage(let m): return storageMessage(m)
            case .notPDF, .notAvailable: return "Couldn't open the file."
            }
        }
        return LoadState<Int>.message(for: error)
    }
}

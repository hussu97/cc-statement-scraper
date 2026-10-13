import Foundation

/// PDFs the Share Extension could not upload (offline, signed out). Kept as
/// files in the App Group; the app sends them on its next foreground. The
/// server dedups on sha256, so a file sent twice is harmless.
public struct PendingUploads: Sendable {
    let directory: URL

    public init(container: URL) {
        directory = container.appendingPathComponent("pending-uploads", isDirectory: true)
    }

    public func save(_ file: UploadFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A unique prefix keeps two "statement.pdf"s apart; it is stripped on send.
        let name = "\(UUID().uuidString.prefix(8))__\(file.filename)"
        try file.data.write(to: directory.appendingPathComponent(name),
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public var count: Int { list().count }

    /// These saved PDFs (sign-out, after the person confirmed the count), each
    /// with its refusal reason. A file that moved to `rejected/` since it was
    /// counted is deleted there; one already sent is gone and skipped. Throws
    /// the first file that couldn't be deleted, after trying them all.
    public func remove(files: [URL]) throws {
        let fm = FileManager.default
        var failure: (any Error)?
        for url in files {
            let candidates = [url, rejectedDirectory.appendingPathComponent(url.lastPathComponent)]
            guard let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            do {
                try fm.removeItem(at: found)
                try? fm.removeItem(at: Self.reasonURL(found))
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    static func originalName(_ url: URL) -> String {
        let name = url.lastPathComponent
        guard let range = name.range(of: "__") else { return name }
        return String(name[range.upperBound...])
    }

    /// Uploads each pending file on its own (extension memory is tight) and
    /// deletes it once the server has it. A failure that will pass (offline,
    /// signed out, server busy) stops the run and keeps the rest for later; a
    /// permanent rejection (too large, not a PDF, no longer an owner) moves that
    /// file to `rejected/` with the reason and carries on, so one bad PDF never
    /// blocks the queue (BACKLOG IOS-16r).
    @discardableResult
    public func flush(profileCode: String, upload: @Sendable (UploadFile) async throws -> UploadResponse) async -> Int {
        var sent = 0
        for url in list() {
            guard let data = try? Data(contentsOf: url) else {
                quarantine(url, reason: "The saved file couldn't be read.")
                continue
            }
            do {
                _ = try await upload(UploadFile(filename: Self.originalName(url), data: data))
                try? FileManager.default.removeItem(at: url)
                sent += 1
            } catch let error as LedgerAPIError where error.kind == .permanent {
                quarantine(url, reason: error.description)
            } catch {
                break
            }
        }
        return sent
    }

    // MARK: Rejected

    /// A PDF the server refused for good, kept so the person can see why.
    public struct Rejected: Sendable, Hashable, Identifiable {
        public var id: URL { url }
        public let url: URL
        public let filename: String
        public let reason: String
    }

    var rejectedDirectory: URL { directory.appendingPathComponent("rejected", isDirectory: true) }

    public func rejected() -> [Rejected] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: rejectedDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let reason = (try? String(contentsOf: Self.reasonURL(url), encoding: .utf8)) ?? "The server refused this PDF."
                return Rejected(url: url, filename: Self.originalName(url), reason: reason)
            }
    }

    /// Deletes a rejected PDF and its reason.
    public func discard(_ item: Rejected) {
        try? FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: Self.reasonURL(item.url))
    }

    func quarantine(_ url: URL, reason: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: rejectedDirectory, withIntermediateDirectories: true)
        let target = rejectedDirectory.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: target)
        if (try? fm.moveItem(at: url, to: target)) == nil {
            try? fm.removeItem(at: url)   // never let it block the queue
            return
        }
        try? Data(reason.utf8).write(to: Self.reasonURL(target), options: .atomic)
    }

    static func reasonURL(_ pdf: URL) -> URL { pdf.appendingPathExtension("reason") }

    /// `"2 PDFs waiting to upload"`, nil when none.
    public var waitingLabel: String? {
        let n = count
        guard n > 0 else { return nil }
        return n == 1 ? "1 PDF waiting to upload" : "\(n) PDFs waiting to upload"
    }
}

extension LedgerServices {
    public var pendingUploads: PendingUploads { PendingUploads(container: config.sharedContainerURL) }

    /// Sends PDFs the Share Extension queued, to the "SMS go to" ledger (the
    /// one the extension named when it saved them). Called when the app becomes active.
    @discardableResult
    public func flushPendingUploads() async -> Int {
        guard let profile = smsTargets.target?.profileCode else { return 0 }
        let api = self.api
        return await pendingUploads.flush(profileCode: profile) { file in
            try await api.uploadStatements(profileCode: profile, files: [file])
        }
    }
}

/// What the Share Extension tells the user.
public enum ShareOutcome: Equatable, Sendable {
    case uploaded(queued: Int, duplicates: Int)
    case savedForLater(Int)
    case noProfile
    case failed(String)

    public var message: String {
        switch self {
        case let .uploaded(queued, duplicates):
            var parts: [String] = []
            if queued > 0 { parts.append(queued == 1 ? "Sent: watch progress in Bank Ledger → Settings → Statements" : "Sent \(queued) PDFs: watch progress in Bank Ledger → Settings → Statements") }
            if duplicates > 0 { parts.append(duplicates == 1 ? "1 already in Bank Ledger" : "\(duplicates) already in Bank Ledger") }
            return parts.isEmpty ? "Nothing to upload." : parts.joined(separator: ". ") + "."
        case .savedForLater(let n):
            return n == 1 ? "Saved. It will upload next time you open Ledger." : "Saved \(n) PDFs. They will upload next time you open Ledger."
        case .noProfile:
            return "Open Ledger → Settings and choose where SMS and statements go (a ledger you own)."
        case .failed(let message):
            return message
        }
    }

    public var isSuccess: Bool {
        switch self {
        case .uploaded, .savedForLater: true
        case .noProfile, .failed: false
        }
    }
}

extension PendingUploads {
    /// Uploads each file; anything that fails for a reason that will pass
    /// (offline, signed out, server down) is kept for the app to send later.
    /// A permanent rejection (not a PDF, not an owner) is reported instead.
    public func share(_ files: [UploadFile], profileCode: String?,
                      upload: @Sendable (UploadFile) async throws -> UploadResponse) async -> ShareOutcome {
        guard let profileCode, !profileCode.isEmpty else { return .noProfile }
        var queued = 0, duplicates = 0, saved = 0
        for file in files {
            do {
                let response = try await upload(file)
                queued += response.uploads.filter { $0.status == "queued" }.count
                duplicates += response.uploads.filter { $0.status != "queued" }.count
            } catch let error as LedgerAPIError where error.isTransient || error == .notSignedIn {
                do {
                    try save(file)
                    saved += 1
                } catch {
                    return .failed("Couldn't save \(file.filename).")
                }
            } catch {
                return .failed((error as? LedgerAPIError)?.description ?? "Upload failed.")
            }
        }
        if saved > 0 && queued + duplicates == 0 { return .savedForLater(saved) }
        return .uploaded(queued: queued, duplicates: duplicates)
    }
}

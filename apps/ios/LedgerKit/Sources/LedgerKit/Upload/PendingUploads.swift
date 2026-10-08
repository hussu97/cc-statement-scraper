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

    static func originalName(_ url: URL) -> String {
        let name = url.lastPathComponent
        guard let range = name.range(of: "__") else { return name }
        return String(name[range.upperBound...])
    }

    /// Uploads each pending file on its own (extension memory is tight) and
    /// deletes it once the server has it. Stops at the first failure.
    @discardableResult
    public func flush(profileCode: String, upload: @Sendable (UploadFile) async throws -> UploadResponse) async -> Int {
        var sent = 0
        for url in list() {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                _ = try await upload(UploadFile(filename: Self.originalName(url), data: data))
                try? FileManager.default.removeItem(at: url)
                sent += 1
            } catch {
                break
            }
        }
        return sent
    }
}

extension LedgerServices {
    public var pendingUploads: PendingUploads { PendingUploads(container: config.sharedContainerURL) }

    /// Sends PDFs the Share Extension queued. Called when the app becomes active.
    @discardableResult
    public func flushPendingUploads() async -> Int {
        guard let profile = selection.profileCode else { return 0 }
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
            if queued > 0 { parts.append(queued == 1 ? "1 statement queued for parsing" : "\(queued) statements queued for parsing") }
            if duplicates > 0 { parts.append(duplicates == 1 ? "1 already in Ledger" : "\(duplicates) already in Ledger") }
            return parts.isEmpty ? "Nothing to upload." : parts.joined(separator: ", ") + "."
        case .savedForLater(let n):
            return n == 1 ? "Saved. It will upload next time you open Ledger." : "Saved \(n) PDFs. They will upload next time you open Ledger."
        case .noProfile:
            return "Open Ledger and choose a ledger first."
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

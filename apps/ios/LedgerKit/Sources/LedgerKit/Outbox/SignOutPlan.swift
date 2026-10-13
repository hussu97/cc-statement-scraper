import Foundation

/// What signing out deletes from this phone: exactly the outbox entries and
/// saved PDFs counted in the confirmation the person agreed to (IOS-12r
/// audit). Anything captured while the confirmation was open is not in it: it
/// stays, stamped with the account that captured it, so no other account can
/// send it.
public struct SignOutPlan: Sendable, Equatable {
    public let queue: DeviceQueue
    public let outboxIDs: Set<UUID>
    /// Share-extension PDFs (waiting or refused), by file.
    public let pdfFiles: [URL]

    public static let empty = SignOutPlan(queue: DeviceQueue(messages: 0, pdfs: 0), outboxIDs: [], pdfFiles: [])

    /// The confirmation, nil when nothing would be deleted.
    public var warning: String? { queue.signOutWarning }

    /// Counts what is on the phone now.
    public static func make(outbox: Outbox, uploads: PendingUploads) async -> SignOutPlan {
        let entries = (try? await outbox.entries()) ?? []
        let files = uploads.list() + uploads.rejected().map(\.url)
        return SignOutPlan(
            queue: DeviceQueue(messages: entries.filter { $0.kind == .sms }.count,
                               payments: entries.filter { $0.kind == .wallet }.count,
                               pdfs: files.count),
            outboxIDs: Set(entries.map(\.id)),
            pdfFiles: files)
    }

    /// Deletes what was counted, nothing more. Throws when something counted
    /// couldn't be deleted, so the app can say so instead of claiming it's gone.
    public func delete(outbox: Outbox, uploads: PendingUploads) async throws {
        var failure: (any Error)?
        if !outboxIDs.isEmpty {
            do { try await outbox.remove(outboxIDs) } catch { failure = error }
        }
        do { try uploads.remove(files: pdfFiles) } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    /// Shown after sign-out when `delete` failed.
    public static let deleteFailedMessage =
        "Signed out, but some SMS, card payments or PDFs couldn't be deleted from this phone. "
        + "They won't be sent to another account; sign in again to delete them in Settings."
}

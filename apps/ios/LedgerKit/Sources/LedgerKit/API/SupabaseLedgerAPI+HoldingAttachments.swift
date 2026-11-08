import Foundation
import Supabase

/// Holding attachments (`20261108112842_holding_attachments.sql`), the way the web writes them
/// (`useUploadHoldingAttachments` / `useRemoveHoldingAttachment` in `apps/web/src/data/holdings.ts`):
/// the object goes to `<profile>/<holding>/<file>` in the private `holding-attachments` bucket, then
/// `add_holding_attachment` records it (taking type and size from Storage). Storage RLS lets
/// members read the ledger's folder and owners upload and delete. Opening one is a short-lived
/// signed URL, as for a statement PDF or a term sheet.
extension SupabaseLedgerAPI {
    public func uploadHoldingAttachment(profileCode: String, upload u: HoldingAttachmentUpload) async throws -> String {
        let bucket = client.storage.from(HoldingAttachments.bucket)
        do {
            try await bucket.upload(u.storagePath, data: u.data, options: FileOptions(contentType: u.mimeType, upsert: false))
        } catch let error as StorageError {
            throw HoldingAttachments.Failure.storage(error.message)
        } catch {
            throw Self.map(error)
        }
        do {
            return try await rpc("add_holding_attachment", String.self, [
                "p_profile_code": .string(profileCode), "p_holding_code": .string(u.holdingCode),
                "p_storage_path": .string(u.storagePath), "p_file_name": .string(u.fileName),
                "p_caption": u.caption.map(AnyJSON.string) ?? .null,
            ])
        } catch {
            // Not recorded: the object would only be unreachable, but it is private data, so it goes.
            _ = try? await bucket.remove(paths: [u.storagePath])
            throw error
        }
    }

    public func holdingAttachmentURL(path: String) async throws -> URL {
        do {
            return try await client.storage.from(HoldingAttachments.bucket)
                .createSignedURL(path: path, expiresIn: StatementPDF.signedURLSeconds)
        } catch let error as StorageError {
            throw HoldingAttachments.Failure.storage(error.message)
        } catch {
            throw Self.map(error)
        }
    }

    public func removeHoldingAttachment(profileCode: String, attachmentCode: String) async throws {
        let path = try await rpc("remove_holding_attachment", String.self, [
            "p_profile_code": .string(profileCode), "p_attachment_code": .string(attachmentCode),
        ])
        // The row is gone, so the file is no longer listed or reachable from the app; a failed
        // delete leaves an orphan object, not a broken screen (the web does the same).
        _ = try? await client.storage.from(HoldingAttachments.bucket).remove(paths: [path])
    }
}

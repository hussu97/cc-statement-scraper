import Foundation
import Supabase

/// A structured note's term sheet, the way the web opens it (`termSheetBlob` in
/// `apps/web/src/data/notes.ts`): `termsheet_path` from `structured_note_detail`, then a
/// short-lived signed URL from the private `term-sheets` bucket. Storage RLS
/// (`term_sheets_bucket_member_read`) lets any member of the ledger read its folder.
extension SupabaseLedgerAPI {
    public func termSheetPDFURL(path: String) async throws -> URL {
        do {
            return try await client.storage.from(TermSheetPDF.bucket)
                .createSignedURL(path: path, expiresIn: StatementPDF.signedURLSeconds)
        } catch let error as StorageError {
            throw StatementPDF.Failure.storage(error.message)
        } catch {
            throw Self.map(error)
        }
    }
}

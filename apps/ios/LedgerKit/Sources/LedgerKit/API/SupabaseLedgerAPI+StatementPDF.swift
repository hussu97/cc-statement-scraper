import Foundation
import Supabase

/// A statement's PDF (PAR-13), the way the web opens it (`documentStoragePath` +
/// `signedDocumentUrl` in `apps/web/src/data/cards.ts`): the document's `storage_path`, read on
/// demand, then a short-lived signed URL from the private `statements` bucket. Storage RLS
/// (`statements_bucket_member_read`) lets any member of the ledger read its folder.
extension SupabaseLedgerAPI {
    public func statementPDFURL(profileCode: String, docCode: String) async throws -> URL {
        struct Row: Decodable { let storagePath: String? }
        let rows = try await read([Row].self) {
            try await client.from("documents").select("storage_path")
                .eq("profile_code", value: profileCode)
                .eq("doc_code", value: docCode)
                .limit(1)
                .execute()
        }
        guard let path = rows.first?.storagePath, !path.isEmpty else { throw StatementPDF.Failure.notAvailable }
        do {
            return try await client.storage.from(StatementPDF.bucket)
                .createSignedURL(path: path, expiresIn: StatementPDF.signedURLSeconds)
        } catch let error as StorageError {
            throw StatementPDF.Failure.storage(error.message)
        } catch {
            throw Self.map(error)
        }
    }
}

import Foundation

/// The holding screen's Attachments (`20261108112842_holding_attachments.sql`): invoices,
/// certificates and other proof kept with the holding. Members list and open them; owners add a
/// photo (sent as JPEG) or a PDF, and remove one. The list is `holding_detail`'s, so a write
/// reloads the screen; the Investments tab's figures don't change, so it isn't told.
extension HoldingDetailModel {
    /// Newest first, as the server sends them.
    public var attachments: [HoldingAttachment] { detail.value?.attachments ?? [] }

    /// The empty state, said only once loaded.
    public func noAttachmentsMessage(canEdit: Bool) -> String? {
        guard detail.value != nil, attachments.isEmpty else { return nil }
        return canEdit
            ? "Add a photo or PDF of the invoice, a certificate or anything else that proves the purchase."
            : "The ledger's owner can add invoices and certificates here."
    }

    /// The Add buttons show for owners; they work once the list has loaded and has room.
    public func canAddAttachment(canEdit: Bool) -> Bool {
        canEdit && detail.value != nil && attachments.count < HoldingAttachments.maxCount && !isSaving
    }

    /// Under the list, for owners: the limit once reached, else how to remove one.
    public func attachmentsNote(canEdit: Bool) -> String? {
        guard canEdit, detail.value != nil else { return nil }
        if attachments.count >= HoldingAttachments.maxCount { return HoldingAttachments.fullMessage }
        return attachments.isEmpty ? "Photos and PDFs up to 10 MB." : "Photos and PDFs up to 10 MB. Swipe a file to remove it."
    }

    /// A photo from the library, already encoded as JPEG by the screen (nil: it couldn't be read).
    /// Named after the day it was added.
    public func addPhoto(_ jpeg: Data?, profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return HoldingDraft.ownerOnlyMessage }
        guard let jpeg else { return HoldingAttachments.unreadablePhoto }
        return await addAttachment(data: jpeg, fileName: HoldingAttachments.photoFileName(on: today()),
                                   mimeType: "image/jpeg", profileCode: profileCode, canEdit: canEdit)
    }

    /// A file picked in Files (a security-scoped URL), read off the main thread; its type comes
    /// from its extension.
    public func addFile(at url: URL, profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return HoldingDraft.ownerOnlyMessage }
        guard let file = await Self.readFile(url) else { return "Couldn't read \(url.lastPathComponent)." }
        return await addAttachment(data: file.data, fileName: file.filename,
                                   mimeType: HoldingAttachments.mimeType(forFileName: file.filename),
                                   profileCode: profileCode, canEdit: canEdit)
    }

    /// Checks the file, uploads it to `<profile>/<holding>/<uuid>.<ext>` and records it. Nil when
    /// added (the notice says so), else the sentence to show.
    public func addAttachment(data: Data, fileName: String, mimeType: String?, profileCode: String,
                              canEdit: Bool) async -> String? {
        guard canEdit else { return HoldingDraft.ownerOnlyMessage }
        if let problem = HoldingAttachments.check(byteCount: data.count, mimeType: mimeType, existing: attachments.count) {
            return problem
        }
        guard let mimeType,
              let path = HoldingAttachments.storagePath(profileCode: profileCode, holdingCode: holdingCode, id: UUID(),
                                                        mimeType: mimeType)
        else { return HoldingAttachments.unsupportedType }
        let name = HoldingAttachments.cleanFileName(fileName, mimeType: mimeType)
        let upload = HoldingAttachmentUpload(holdingCode: holdingCode, storagePath: path, fileName: name,
                                             mimeType: mimeType, data: data)
        isAddingAttachment = true
        defer { isAddingAttachment = false }
        return await write(profileCode: profileCode, saved: "\(name) added.", errors: .attachment, refreshesTab: false) {
            _ = try await $0.uploadHoldingAttachment(profileCode: profileCode, upload: upload)
        }
    }

    /// Forgets the attachment and deletes its file. Nil when removed, else the sentence to show.
    public func removeAttachment(_ attachment: HoldingAttachment, profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return HoldingDraft.ownerOnlyMessage }
        let code = attachment.attachmentCode
        return await write(profileCode: profileCode, saved: "\(attachment.label) removed.", errors: .attachment,
                           refreshesTab: false) {
            try await $0.removeHoldingAttachment(profileCode: profileCode, attachmentCode: code)
        }
    }

    /// A picked file's bytes, on the cooperative pool (a file in iCloud Drive may download first).
    @concurrent
    nonisolated static func readFile(_ url: URL) async -> UploadFile? { try? StatementsModel.readFile(url) }
}

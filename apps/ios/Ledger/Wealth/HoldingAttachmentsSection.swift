import LedgerKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the Attachments section asks the holding screen to present: a photo picked, the PDF
/// picker, a removal to confirm, and a failed write. Held by `HoldingDetailView`, so the pickers,
/// dialog and sheets hang off the screen rather than a List section.
struct AttachmentRequests {
    var photo: PhotosPickerItem?
    var importingPDF = false
    var removing: HoldingAttachment?
    var error: String?
}

/// A holding's attachments (invoice photos and PDFs, certificates), newest first: tap one to open
/// it. Owners add a photo from the library or a PDF from Files, and swipe (or long-press) a file
/// to remove it. `HoldingDetailModel+Attachments` decides; `HoldingAttachmentPresentations`
/// presents.
struct HoldingAttachmentsSection: View {
    let model: HoldingDetailModel
    let canEdit: Bool
    @Binding var requests: AttachmentRequests

    var body: some View {
        let canAdd = model.canAddAttachment(canEdit: canEdit)
        Section {
            if canEdit {
                PhotosPicker(selection: $requests.photo, matching: .images) {
                    Label("Add a photo", systemImage: "photo.badge.plus")
                }
                .tint(Palette.accent)
                .disabled(!canAdd)
                Button { requests.importingPDF = true } label: {
                    Label("Add a PDF", systemImage: "doc.badge.plus")
                }
                .tint(Palette.accent)
                .disabled(!canAdd)
            }
            if model.isAddingAttachment {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Adding…").font(Typography.rowMeta).foregroundStyle(Palette.muted)
                }
            }
            if model.detail.value == nil, let message = model.detail.errorMessage {
                Text(message).font(Typography.rowMeta).foregroundStyle(Palette.danger)
            } else if model.detail.value == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let empty = model.noAttachmentsMessage(canEdit: canEdit) {
                Text(empty).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(model.attachments) { attachment in
                Button { open(attachment) } label: {
                    AttachmentRow(attachment: attachment,
                                  isOpening: model.attachmentViewer.openingCode == attachment.attachmentCode)
                }
                .buttonStyle(.plain)
                .disabled(model.attachmentViewer.isLoading)
                .accessibilityHint("Opens the file")
                .swipeActions(edge: .trailing) {
                    if canEdit {
                        Button("Remove") { requests.removing = attachment }.tint(Palette.danger)
                    }
                }
                .contextMenu {
                    if canEdit {
                        Button("Remove", systemImage: "trash", role: .destructive) { requests.removing = attachment }
                    }
                }
            }
        } header: {
            Text("Attachments")
        } footer: {
            if let note = model.attachmentsNote(canEdit: canEdit) { Text(note) }
        }
    }

    private func open(_ attachment: HoldingAttachment) {
        Task { await model.attachmentViewer.open(attachment) }
    }
}

/// One file: a photo or PDF glyph, its caption (else file name), and when it was added and how big.
private struct AttachmentRow: View {
    let attachment: HoldingAttachment
    let isOpening: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.systemImage)
                .foregroundStyle(Palette.muted)
                .frame(width: 36, height: 36)
                .background(Palette.surface3, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.label).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                Text(attachment.detailText).font(Typography.caption).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if isOpening {
                ProgressView()
            } else {
                Image(systemName: "chevron.right").font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
        .frame(minHeight: Metrics.tapMin)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The Attachments section's pickers, removal dialog, viewer sheet and alerts, applied to the
/// holding screen: `.modifier(HoldingAttachmentPresentations(…))`.
struct HoldingAttachmentPresentations: ViewModifier {
    let model: HoldingDetailModel
    let profileCode: String
    let canEdit: Bool
    @Binding var requests: AttachmentRequests

    func body(content: Content) -> some View {
        content
            .onChange(of: requests.photo) { _, item in
                guard let item else { return }
                requests.photo = nil
                Task { await addPhoto(item) }
            }
            .fileImporter(isPresented: $requests.importingPDF, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    requests.error = await model.addFile(at: url, profileCode: profileCode, canEdit: canEdit)
                }
            }
            .confirmationDialog(requests.removing.map(HoldingAttachments.removeTitle) ?? "",
                                isPresented: Binding(get: { requests.removing != nil },
                                                     set: { if !$0 { requests.removing = nil } }),
                                titleVisibility: .visible, presenting: requests.removing) { attachment in
                Button("Remove", role: .destructive) { remove(attachment) }
            } message: { _ in
                Text(HoldingAttachments.removeMessage)
            }
            .sheet(item: Binding(get: { model.attachmentViewer.document },
                                 set: { if $0 == nil { model.attachmentViewer.close() } })) { document in
                AttachmentViewerSheet(document: document)
            }
            .alert("Couldn't change the attachments",
                   isPresented: Binding(get: { requests.error != nil }, set: { if !$0 { requests.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(requests.error ?? "")
            }
            .alert("Couldn't open the file",
                   isPresented: Binding(get: { model.attachmentViewer.errorMessage != nil },
                                        set: { if !$0 { model.attachmentViewer.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.attachmentViewer.errorMessage ?? "")
            }
    }

    /// The picked photo's bytes (HEIC, JPEG, PNG…), redrawn as JPEG off the main thread.
    private func addPhoto(_ item: PhotosPickerItem) async {
        var jpeg: Data?
        if let original = try? await item.loadTransferable(type: Data.self) {
            jpeg = await PhotoJPEG.encode(original)
        }
        requests.error = await model.addPhoto(jpeg, profileCode: profileCode, canEdit: canEdit)
    }

    private func remove(_ attachment: HoldingAttachment) {
        Task {
            requests.error = await model.removeAttachment(attachment, profileCode: profileCode, canEdit: canEdit)
        }
    }
}

/// A library photo as the JPEG the bucket gets: its longer side scaled down to
/// `HoldingAttachments.photoMaxSide`, orientation baked in, at `HoldingAttachments.photoQuality`.
enum PhotoJPEG {
    @concurrent
    nonisolated static func encode(_ data: Data) async -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = HoldingAttachments.photoSize(width: Double(image.size.width * image.scale),
                                                height: Double(image.size.height * image.scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let target = CGSize(width: size.width, height: size.height)
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { context in
            // JPEG has no transparency: a PNG's clear pixels become white paper, not black.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return drawn.jpegData(compressionQuality: CGFloat(HoldingAttachments.photoQuality))
    }
}

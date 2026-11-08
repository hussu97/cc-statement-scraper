import LedgerKit
import SwiftUI
import UIKit

/// A holding's attachment, shown from memory: a PDF in PDFKit, a photo full screen with pinch to
/// zoom. Share hands it on under its recorded name. `HoldingAttachmentViewer` signs and downloads
/// it; the bytes go when the sheet closes.
struct AttachmentViewerSheet: View {
    let document: HoldingAttachmentViewer.Document
    /// Decoded once per presentation; nil when the bytes aren't a picture UIKit can draw.
    private let image: UIImage?
    @Environment(\.dismiss) private var dismiss

    init(document: HoldingAttachmentViewer.Document) {
        self.document = document
        image = document.isPDF ? nil : UIImage(data: document.data)
    }

    var body: some View {
        NavigationStack {
            content
                .ignoresSafeArea(edges: .bottom)
                .background(Palette.bg)
                .navigationTitle(document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { share }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if document.isPDF {
            PDFKitView(data: document.data)
        } else if let image {
            ZoomableImageView(image: image)
                .accessibilityLabel(document.title)
                .accessibilityAddTraits(.isImage)
        } else {
            EmptyCard(systemImage: "photo", message: "Couldn't show this photo.")
                .padding(Metrics.gutter)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var share: some View {
        if document.isPDF {
            ShareLink(item: SharedPDF(data: document.data, filename: document.filename),
                      preview: SharePreview(document.filename, image: Image(systemName: "doc.richtext"))) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share file")
        } else if let image {
            let picture = Image(uiImage: image)
            ShareLink(item: picture, preview: SharePreview(document.filename, image: picture)) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share photo")
        }
    }
}

/// A photo fitted to the screen that pinches and double-taps to zoom (UIScrollView).
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ view: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func toggleZoom(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            scroll.setZoomScale(scroll.zoomScale > scroll.minimumZoomScale ? scroll.minimumZoomScale : 2.5, animated: true)
        }
    }
}

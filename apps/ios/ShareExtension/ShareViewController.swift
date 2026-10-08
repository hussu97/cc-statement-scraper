import LedgerKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Add to Ledger": share statement PDFs from Mail, Files or a bank app.
/// Uses the app's session from the shared keychain; when offline or signed
/// out the PDFs are kept in the App Group and the app sends them later.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        let services = try? LedgerServices.fromBundle()
        Telemetry.start(target: .shareExtension, config: services?.config)

        let host = UIHostingController(rootView: ShareView(state: state) { [weak self] in self?.finish() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }

        Task { @MainActor in
            guard let services else {
                state.finish(.failed("Ledger isn't configured."))
                return
            }
            let files = await Self.load(providers)
            state.fileCount = files.count
            let outcome = await services.pendingUploads.share(files, profileCode: services.selection.profileCode) { file in
                try await services.uploadStatements([file])
            }
            Telemetry.breadcrumb("statement_share", outcome: outcome.isSuccess ? "ok" : "failed",
                                 data: ["files": "\(files.count)"])
            state.finish(outcome)
        }
    }

    private func finish() {
        Telemetry.flush()
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Copies each PDF's bytes out of the provider (its file URL is only
    /// valid inside the callback).
    private static func load(_ providers: [NSItemProvider]) async -> [UploadFile] {
        var files: [UploadFile] = []
        for (index, provider) in providers.enumerated() {
            let name = provider.suggestedName.map { $0.lowercased().hasSuffix(".pdf") ? $0 : "\($0).pdf" }
                ?? "statement-\(index + 1).pdf"
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data { files.append(UploadFile(filename: name, data: data)) }
        }
        return files
    }
}

@MainActor
@Observable
final class ShareState {
    var fileCount = 0
    var outcome: ShareOutcome?

    func finish(_ outcome: ShareOutcome) { self.outcome = outcome }
}

struct ShareView: View {
    let state: ShareState
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to Ledger").font(.system(.title, design: .serif))
            if let outcome = state.outcome {
                Label(outcome.message, systemImage: outcome.isSuccess ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(outcome.isSuccess ? Palette.positive : Palette.danger)
                    .font(Typography.body)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(state.fileCount == 0 ? "Reading PDFs…" : "Uploading \(state.fileCount) PDF(s)…")
                        .font(Typography.body).foregroundStyle(Palette.muted)
                }
            }
            Spacer()
            Button(action: done) {
                Text("Done").frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .disabled(state.outcome == nil)
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bg)
    }
}

import LedgerKit
import SwiftUI

/// One `LedgerServices` per process. The App Intent runs in this process too
/// (launched in the background when the app is not running), so it shares the
/// outbox actor and the Supabase client with the UI.
enum AppServices {
    static let result: Result<LedgerServices, any Error> = Result {
        try LedgerServices.fromBundle(debugSessionFallback: BuildFlavor.isDebug)
    }
    static var shared: LedgerServices? { try? result.get() }
}

/// This target's own build flavour (LedgerKit is compiled separately).
enum BuildFlavor {
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif
}

@main
struct LedgerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel?

    init() {
        Telemetry.start(target: .app, config: AppServices.shared?.config, isDebugBuild: BuildFlavor.isDebug)
        _model = State(initialValue: AppServices.shared.map { AppModel(services: $0) })
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    RootView(model: model)
                } else {
                    ConfigErrorView(message: AppServices.errorMessage)
                }
            }
            .tint(Palette.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let model else { return }
            Task { await model.becameActive() }
        }
    }
}

extension AppServices {
    static var errorMessage: String {
        if case .failure(let error) = result { return String(describing: error) }
        return ""
    }
}

/// Shown when Secrets.xcconfig is missing — a build without Supabase config.
struct ConfigErrorView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bank Ledger isn't configured").font(Typography.display)
            Text(message).font(Typography.body).foregroundStyle(Palette.muted)
            Text("See apps/ios/README.md → Secrets.").font(Typography.caption).foregroundStyle(Palette.subtle)
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bg)
    }
}

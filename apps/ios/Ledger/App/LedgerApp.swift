import LedgerKit
import SwiftUI
import UserNotifications

/// One `LedgerServices` per process. The App Intent runs in this process too
/// (launched in the background when the app is not running), so it shares the
/// outbox actor and the Supabase client with the UI.
enum AppServices {
    static let result: Result<LedgerServices, any Error> = Result {
        try LedgerServices.fromBundle(debugSessionFallback: BuildFlavor.isDebug)
    }
    static var shared: LedgerServices? { try? result.get() }

    /// Watches connectivity for the life of the process (app or intent).
    static let connectivity: ConnectivityWatcher? = shared.map(ConnectivityWatcher.init)
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
    @State private var cover: PrivacyCoverWindow?

    init() {
        Telemetry.start(target: .app, config: AppServices.shared?.config, isDebugBuild: BuildFlavor.isDebug)
        let model = AppServices.shared.map { AppModel(services: $0) }
        model?.receiveIntentLinks()   // the Controls' intents (N-4)
        _model = State(initialValue: model)
        _cover = State(initialValue: model.map { PrivacyCoverWindow(lock: $0.lock) })
        if let services = AppServices.shared {
            BackgroundSync.register(services)
            _ = AppServices.connectivity
        }
        // A tap on a notification opens its ledger:// link (N-1).
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        NotificationRouter.shared.open = { url in _ = model?.open(url: url) }
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
            // ledger://review, ledger://uncategorised, ledger://add-statement (LedgerKit AppLink).
            .onOpenURL { url in model?.open(url: url) }
            // The privacy cover lives in its own window above every sheet (IOS-22).
            .background(WindowSceneReader { scene in cover?.attach(to: scene) })
        }
        .onChange(of: scenePhase) { _, phase in
            guard let model else { return }
            // Synchronous: the cover is up in this turn, before the app-switcher snapshot.
            model.lock.phaseChanged(AppLock.Phase(phase))
            switch phase {
            case .active:
                Task {
                    await model.becameActive()
                    await LocalNotifications.refreshOutbox(model.services)
                    await LocalNotifications.refreshDueReminders(model.services,
                                                                 profileCode: model.profiles.selected?.profileCode)
                }
            // Leaving with messages waiting: let iOS send them later.
            case .background:
                Task {
                    await BackgroundSync.schedule(model.services)
                    await LocalNotifications.refreshOutbox(model.services)
                }
            default: break
            }
        }
    }
}

extension AppLock.Phase {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        default: self = .inactive
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
            Text("See apps/ios/README.md → Secrets.").font(Typography.caption).foregroundStyle(Palette.muted)
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bg)
    }
}

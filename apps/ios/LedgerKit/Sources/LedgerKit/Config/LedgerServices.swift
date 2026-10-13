import Foundation
import Supabase
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

/// The ledger the app is showing, in the App Group's defaults. SMS and shared
/// PDFs do NOT follow it; they go to `SMSTargetStore.target`.
public struct ProfileSelection: @unchecked Sendable {
    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults
    static let key = "ledger.selectedProfileCode"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var profileCode: String? {
        get { defaults.string(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// The composition root shared by the app, the App Intent and the Share
/// Extension. Each process builds its own; they meet in the keychain (session),
/// the App Group defaults (profile) and the App Group outbox file.
public final class LedgerServices: Sendable {
    public let config: LedgerConfig
    public let client: SupabaseClient
    public let api: SupabaseLedgerAPI
    public let outbox: Outbox
    public let outboxSync: OutboxSync
    public let selection: ProfileSelection
    public let smsTargets: SMSTargetStore
    /// The account last signed in on this phone (kept after sign-out).
    public let deviceUser: DeviceUserStore
    public let captureLog: CaptureLog
    public let sessionStorage: SharedKeychainStorage
    /// PDFs the Share Extension saved for later, in the App Group.
    public let pendingUploads: PendingUploads
    /// Settings → Notifications switches (read by the App Intents too).
    public let notices: NoticePreferences
    /// The Home and Lock Screen widgets' snapshot and privacy flag, in the App Group (N-2).
    public let widgets: WidgetSnapshotStore

    /// `debugSessionFallback`: Debug builds only — keep the session in memory
    /// when the keychain refuses it (an unsigned simulator build), instead of
    /// appearing signed in while every request goes out anonymous.
    public init(config: LedgerConfig, session: URLSession = .shared, debugSessionFallback: Bool = false) {
        self.config = config
        let storage = SharedKeychainStorage(accessGroup: config.keychainGroup, allowsMemoryFallback: debugSessionFallback)
        sessionStorage = storage
        client = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabasePublishableKey,
            options: SupabaseClientOptions(
                db: .init(decoder: LedgerJSON.makeDecoder()),
                auth: .init(storage: storage, storageKey: "ledger.auth", emitLocalSessionAsInitialSession: true),
                global: .init(session: session)))
        api = SupabaseLedgerAPI(client: client, config: config, session: session)
        // Looked up once: each lookup is a system call, and this runs in the App's init.
        let defaults = config.sharedDefaults
        let container = config.sharedContainerURL
        let targets = SMSTargetStore(defaults: defaults)
        smsTargets = targets
        let users = DeviceUserStore(defaults: defaults)
        deviceUser = users
        // SMS and payments saved while no ledger was known go to the "SMS go to"
        // ledger as soon as one is, if it's the account they were captured under.
        outbox = Outbox(fileURL: Outbox.defaultURL(container: container), api: api,
                        pendingTarget: { targets.target?.profileCode }, deviceUser: { users.userID })
        outboxSync = OutboxSync(outbox: outbox)
        selection = ProfileSelection(defaults: defaults)
        captureLog = CaptureLog(defaults: defaults)
        pendingUploads = PendingUploads(container: container)
        notices = NoticePreferences(defaults: defaults)
        widgets = WidgetSnapshotStore(container: container, defaults: defaults, reload: Self.reloadWidgets)
    }

    /// Every widget re-reads the snapshot. Free from the foreground app; the
    /// store calls it only when something on a widget changed.
    @Sendable static func reloadWidgets() {
        #if canImport(WidgetKit) && os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Reads config from the running bundle. Extensions carry the same `Ledger*`
    /// Info.plist keys as the app.
    public static func fromBundle(_ bundle: Bundle = .main, debugSessionFallback: Bool = false) throws -> LedgerServices {
        LedgerServices(config: try LedgerConfig.load(bundle: bundle), debugSessionFallback: debugSessionFallback)
    }

    /// The intent's whole path, bound to this process's outbox and the
    /// "SMS go to" ledger.
    public func smsIntake() -> SMSIntake {
        let targets = smsTargets
        return SMSIntake(outbox: outbox, target: { targets.target }, log: captureLog)
    }

    /// "Log Card Payment"'s path: same outbox, same "SMS go to" ledger.
    public func walletIntake() -> WalletIntake {
        let targets = smsTargets
        return WalletIntake(outbox: outbox, target: { targets.target }, log: captureLog)
    }

    /// The App Intents beyond SMS (N-3): spend, what's due, categorise the last
    /// purchase, for the ledger the app shows, with the widgets' snapshot as the
    /// offline fallback.
    public func questions() -> LedgerQuestions {
        let selection = selection, widgets = widgets
        return LedgerQuestions(api: api, profileCode: { selection.profileCode }, snapshot: { widgets.read() })
    }

    /// What sign-out would delete from this phone: SMS and card payments in
    /// the outbox (sent or not yet), and the share extension's PDFs.
    public func signOutPlan() async -> SignOutPlan {
        await SignOutPlan.make(outbox: outbox, uploads: pendingUploads)
    }

    /// Sign-out, after the person confirmed: exactly what `plan` counted goes.
    public func delete(_ plan: SignOutPlan) async throws {
        try await plan.delete(outbox: outbox, uploads: pendingUploads)
    }

    /// The share extension's upload to the "SMS go to" ledger, using the shared session.
    public func uploadStatements(_ files: [UploadFile]) async throws -> UploadResponse {
        guard let profile = smsTargets.target?.profileCode else { throw LedgerAPIError.noProfile }
        return try await api.uploadStatements(profileCode: profile, files: files)
    }
}

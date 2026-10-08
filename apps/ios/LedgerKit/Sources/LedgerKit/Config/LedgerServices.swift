import Foundation
import Supabase

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
    public let selection: ProfileSelection
    public let smsTargets: SMSTargetStore
    public let captureLog: CaptureLog
    public let sessionStorage: SharedKeychainStorage

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
        outbox = Outbox(fileURL: Outbox.defaultURL(container: config.sharedContainerURL), api: api)
        selection = ProfileSelection(defaults: config.sharedDefaults)
        smsTargets = SMSTargetStore(defaults: config.sharedDefaults)
        captureLog = CaptureLog(defaults: config.sharedDefaults)
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

    /// The share extension's upload to the "SMS go to" ledger, using the shared session.
    public func uploadStatements(_ files: [UploadFile]) async throws -> UploadResponse {
        guard let profile = smsTargets.target?.profileCode else { throw LedgerAPIError.noProfile }
        return try await api.uploadStatements(profileCode: profile, files: files)
    }
}

import Foundation
import Supabase

/// The selected profile, in the App Group's defaults so the App Intent and the
/// Share Extension post to the same ledger the app shows.
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

    public init(config: LedgerConfig, session: URLSession = .shared) {
        self.config = config
        let storage = SharedKeychainStorage(accessGroup: config.keychainGroup)
        client = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseAnonKey,
            options: SupabaseClientOptions(
                db: .init(decoder: LedgerJSON.makeDecoder()),
                auth: .init(storage: storage, storageKey: "ledger.auth", emitLocalSessionAsInitialSession: true),
                global: .init(session: session)))
        api = SupabaseLedgerAPI(client: client, config: config, session: session)
        outbox = Outbox(fileURL: Outbox.defaultURL(container: config.sharedContainerURL), api: api)
        selection = ProfileSelection(defaults: config.sharedDefaults)
    }

    /// Reads config from the running bundle. Extensions carry the same `Ledger*`
    /// Info.plist keys as the app.
    public static func fromBundle(_ bundle: Bundle = .main) throws -> LedgerServices {
        LedgerServices(config: try LedgerConfig.load(bundle: bundle))
    }

    /// The intent's whole path, bound to this process's outbox and selection.
    public func smsIntake() -> SMSIntake {
        let selection = self.selection
        return SMSIntake(outbox: outbox, profileCode: { selection.profileCode })
    }

    /// The share extension's upload, using the shared session.
    public func uploadStatements(_ files: [UploadFile]) async throws -> UploadResponse {
        guard let profile = selection.profileCode else { throw LedgerAPIError.noProfile }
        return try await api.uploadStatements(profileCode: profile, files: files)
    }
}

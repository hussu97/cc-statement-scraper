import Foundation

/// Runtime configuration, read from the host bundle's Info.plist. The values
/// come from `Config/*.xcconfig` (secrets from the gitignored `Secrets.xcconfig`),
/// so the app, the App Intent and the Share Extension all see the same ones.
public struct LedgerConfig: Sendable, Equatable {
    public let supabaseURL: URL
    public let supabasePublishableKey: String
    public let sentryDSN: String?
    public let environment: String
    /// `group.<prefix>` — the outbox file and the selected profile live here.
    public let appGroup: String
    /// `<TeamID>.<prefix>.shared` — the auth session lives here.
    public let keychainGroup: String?

    public init(
        supabaseURL: URL,
        supabasePublishableKey: String,
        sentryDSN: String? = nil,
        environment: String = "local",
        appGroup: String,
        keychainGroup: String? = nil
    ) {
        self.supabaseURL = supabaseURL
        self.supabasePublishableKey = supabasePublishableKey
        self.sentryDSN = sentryDSN
        self.environment = environment
        self.appGroup = appGroup
        self.keychainGroup = keychainGroup
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case missing(String)
        /// A server-only key (`sb_secret_…` or a service_role JWT) was configured.
        case secretKey(String)
        public var description: String {
            switch self {
            case .missing(let key):
                "Info.plist key \(key) is empty. Copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig."
            case .secretKey(let key):
                "Info.plist key \(key) holds a secret key. The app takes the publishable (sb_publishable_…) key only."
            }
        }
    }

    /// Reads `Ledger*` keys from `bundle`'s Info.plist.
    public static func load(bundle: Bundle = .main) throws -> LedgerConfig {
        try load(info: bundle.infoDictionary ?? [:])
    }

    public static func load(info: [String: Any]) throws -> LedgerConfig {
        func value(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // An unset xcconfig variable expands to "" (or stays "$(VAR)" in a plain copy).
            return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
        }
        guard let urlString = value("LedgerSupabaseURL"), let url = URL(string: urlString) else {
            throw ConfigError.missing("LedgerSupabaseURL")
        }
        guard let publishable = value("LedgerSupabasePublishableKey") else { throw ConfigError.missing("LedgerSupabasePublishableKey") }
        // Never ship a key that bypasses RLS: refuse to start rather than run with it.
        guard !publishable.hasPrefix("sb_secret_") else { throw ConfigError.secretKey("LedgerSupabasePublishableKey") }
        guard let group = value("LedgerAppGroup") else { throw ConfigError.missing("LedgerAppGroup") }
        let keychain = value("LedgerKeychainGroup").map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        return LedgerConfig(
            supabaseURL: url,
            supabasePublishableKey: publishable,
            sentryDSN: value("LedgerSentryDSN"),
            environment: value("LedgerEnvironment") ?? "local",
            appGroup: group,
            keychainGroup: keychain
        )
    }

    /// The App Group container; falls back to Application Support when the
    /// entitlement is missing (an unsigned simulator build), so nothing crashes —
    /// the extension just won't see the app's outbox.
    public var sharedContainerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ledger", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    public var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    public var functionsURL: URL { supabaseURL.appendingPathComponent("functions/v1") }
}

import Foundation
import Sentry

/// The three processes that run Ledger code on the phone. Each starts Sentry
/// itself — an App Intent and a Share Extension do not share the app's SDK.
public enum TelemetryTarget: String, Sendable {
    case app
    case intent
    case shareExtension = "share_extension"
}

/// Sentry for every iOS runtime (CLAUDE.md §6). `sendDefaultPii` is off, the
/// scrubber runs on every event and breadcrumb, and only opaque codes are tagged.
public enum Telemetry {
    /// `ledger-ios@1.0.0+42`, from the bundle's version and build.
    public static func releaseName(info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "ledger-ios@\(version)+\(build)"
    }

    /// Scope tags on every event. `ledger-apps` is shared with the web app
    /// (app=web), so `app` separates the platforms; `target` the iOS process.
    public static func scopeTags(target: TelemetryTarget) -> [String: String] {
        ["app": "ios", "target": target.rawValue]
    }

    /// Environments that never report to Sentry, even with a DSN set.
    public static let localEnvironments: Set<String> = ["local", "development", "dev", "test", "debug"]

    /// Whether this LedgerKit build was compiled for debugging.
    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Sentry runs only for a release build with a DSN and a non-local
    /// environment (`LEDGER_ENVIRONMENT`), so simulator and local runs never
    /// send events. Pure, so it is unit-tested.
    public static func shouldStart(dsn: String?, environment: String?, isDebugBuild: Bool) -> Bool {
        guard let dsn, !dsn.trimmingCharacters(in: .whitespaces).isEmpty, !isDebugBuild else { return false }
        let env = (environment ?? "local").trimmingCharacters(in: .whitespaces).lowercased()
        return !env.isEmpty && !localEnvironments.contains(env)
    }

    /// No-op unless `shouldStart` (a release build, a DSN, a non-local
    /// environment), and when this process already started Sentry — the intent
    /// runs inside the app process, which may have started it as `.app`.
    /// `isDebugBuild` defaults to LedgerKit's own flag; the app passes its own.
    public static func start(target: TelemetryTarget, config: LedgerConfig?, bundle: Bundle = .main,
                             isDebugBuild: Bool = Telemetry.isDebugBuild) {
        guard shouldStart(dsn: config?.sentryDSN, environment: config?.environment, isDebugBuild: isDebugBuild),
              let dsn = config?.sentryDSN, !SentrySDK.isEnabled else { return }
        let info = bundle.infoDictionary
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = config?.environment ?? "local"
            options.releaseName = releaseName(info: info)
            options.dist = info?["CFBundleVersion"] as? String
            options.sendDefaultPii = false
            options.tracesSampleRate = target == .app ? 0.1 : 0.05
            options.maxBreadcrumbs = 50
            options.enableAutoSessionTracking = target == .app
            #if os(iOS)
            // Screenshots and view hierarchies would capture on-screen
            // transactions; never attach them.
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.enableAppHangTracking = target == .app
            options.enableWatchdogTerminationTracking = target == .app
            #endif
            options.beforeSend = { event in TelemetryScrubber.scrub(event) }
            options.beforeBreadcrumb = { crumb in TelemetryScrubber.scrub(breadcrumb: crumb) }
            options.beforeSendSpan = { span in TelemetryScrubber.scrub(span: span) }
        }
        SentrySDK.configureScope { scope in
            for (key, value) in scopeTags(target: target) { scope.setTag(value: value, key: key) }
        }
    }

    /// Tags the active profile. Profile codes are opaque, so they are allowed.
    public static func setProfile(code: String?) {
        SentrySDK.configureScope { scope in
            if let code { scope.setTag(value: code, key: "profile_code") } else { scope.removeTag(key: "profile_code") }
        }
    }

    public static func setUser(id: String?) {
        SentrySDK.setUser(id.map { let u = User(); u.userId = $0; return u })
    }

    /// A breadcrumb with an outcome only — the SMS intent records `sms_ingest`
    /// plus how it ended, never the message.
    public static func breadcrumb(_ category: String, outcome: String, data: [String: String] = [:]) {
        let crumb = Breadcrumb(level: .info, category: category)
        crumb.message = outcome
        for (key, value) in data { crumb.setData(value: value, key: key) }
        SentrySDK.addBreadcrumb(crumb)
    }

    public static func capture(_ error: any Error, tags: [String: String] = [:]) {
        SentrySDK.capture(error: error) { scope in
            for (key, value) in tags { scope.setTag(value: value, key: key) }
        }
    }

    /// Debug-only crash used to verify symbolication end to end.
    public static func crashForTesting() {
        SentrySDK.crash()
    }

    /// Extensions are killed soon after they finish; give queued events a chance.
    public static func flush(timeout: TimeInterval = 2) {
        SentrySDK.flush(timeout: timeout)
    }
}

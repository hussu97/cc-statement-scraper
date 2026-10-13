import Foundation

/// Which app hangs Sentry reports, per process. Pure, so the policy is unit-tested
/// (`TelemetryHangPolicyTests`); `Telemetry.start` applies it to the SDK options.
///
/// * **Fully-blocking hangs are reported** (the app process only). The main thread
///   rendered no frame for `timeout`, so the stack Sentry captures is where it was stuck:
///   actionable, and the kind our own code causes.
/// * **Non-fully-blocking hangs are not.** Frames still rendered, so the captured stack is
///   a moment in a busy run loop, not the blocking call (Sentry's own docs say so). Build
///   26 sent one from a double-tap in a text field on an iOS beta (UIKit text selection,
///   `NSClassFromString`, InputAnalytics): system work we can neither see nor fix.
/// * The App Intent, the Share Extension and the widgets run headless or briefly: no hang tracking.
public struct HangReporting: Equatable, Sendable {
    /// App-hang tracking is on.
    public let enabled: Bool
    /// How long the main thread must be stuck before it counts (Sentry's default, 2 s).
    public let timeout: TimeInterval
    /// Also report hangs during which a few frames still rendered.
    public let reportsNonFullyBlocking: Bool

    public static func forTarget(_ target: TelemetryTarget) -> HangReporting {
        switch target {
        case .app: HangReporting(enabled: true, timeout: 2, reportsNonFullyBlocking: false)
        case .intent, .shareExtension, .widgets: HangReporting(enabled: false, timeout: 2, reportsNonFullyBlocking: false)
        }
    }
}

import Foundation

/// When the outbox is sent without the user doing anything, beyond the
/// intent's own attempt and the app coming to the foreground:
/// * while this process runs, the moment the network comes back
///   (`pathChanged`, fed by an `NWPathMonitor`);
/// * otherwise from background tasks iOS runs later, which the app schedules
///   whenever something is waiting (`plan`). The processing task requires a
///   network connection, so iOS starts it once one is back, even when the app
///   isn't running.
public actor OutboxSync {
    /// The background task identifiers, derived from the app's bundle id so no
    /// identity is hard-coded (the bundle prefix lives in the gitignored
    /// `Config/Identity.xcconfig`). Info.plist `BGTaskSchedulerPermittedIdentifiers`
    /// lists the same two as `$(LEDGER_BUNDLE_PREFIX).outbox-refresh` / `.outbox-send`,
    /// and the app's bundle id is `$(LEDGER_BUNDLE_PREFIX)`.
    public struct TaskIDs: Sendable, Equatable {
        public static let refreshSuffix = "outbox-refresh"
        public static let processingSuffix = "outbox-send"

        public let refresh: String
        public let processing: String

        public init(bundleIdentifier: String) {
            refresh = "\(bundleIdentifier).\(Self.refreshSuffix)"
            processing = "\(bundleIdentifier).\(Self.processingSuffix)"
        }

        public var all: [String] { [refresh, processing] }
    }

    /// The IDs for this process's bundle (the app: the intent runs in it too).
    public static var taskIDs: TaskIDs {
        TaskIDs(bundleIdentifier: Bundle.main.bundleIdentifier ?? "ledger")
    }
    public static var refreshTaskID: String { taskIDs.refresh }
    public static var processingTaskID: String { taskIDs.processing }

    /// What to ask `BGTaskScheduler` for.
    public struct Plan: Sendable, Equatable {
        public let earliestBegin: Date
    }

    private let outbox: Outbox
    private var lastSatisfied: Bool?

    public init(outbox: Outbox) {
        self.outbox = outbox
    }

    /// The background request to submit, or nil (cancel any) when nothing is
    /// waiting. Parked entries need the user, so they never schedule work.
    public static func plan(_ status: OutboxStatus, now: Date = Date()) -> Plan? {
        guard status.pending > 0 else { return nil }
        return Plan(earliestBegin: max(now, status.nextAttemptAt ?? now))
    }

    public func currentPlan(now: Date = Date()) async -> Plan? {
        Self.plan(await outbox.status(), now: now)
    }

    /// The network path changed. Sends everything waiting (ignoring backoff:
    /// the reason it waited is gone) when a connection is back; nil otherwise.
    /// The first report only sets the baseline, since the app sends on
    /// launch and foreground anyway.
    @discardableResult
    public func pathChanged(satisfied: Bool) async -> FlushReport? {
        let previous = lastSatisfied
        lastSatisfied = satisfied
        guard satisfied, previous == false else { return nil }
        guard await outbox.status().pending > 0 else { return nil }
        return await outbox.flush(force: true)
    }

    /// A background task's run: send everything waiting.
    @discardableResult
    public func runBackgroundTask() async -> FlushReport {
        await outbox.flush(force: true)
    }
}

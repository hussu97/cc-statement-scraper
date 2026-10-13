import BackgroundTasks
import LedgerKit
import Network

/// Plumbing for `OutboxSync` (LedgerKit decides): the `BGTaskScheduler`
/// handlers and requests, and the `NWPathMonitor` that reports connectivity.
///
/// Two requests while something waits: a processing task that requires a
/// network connection (iOS starts it once one is back, even with the app not
/// running) and an app refresh as a second, usage-driven chance.
enum BackgroundSync {
    /// Must run before the app finishes launching (the App's `init`), once
    /// per process. The intent launches this process too, so it's registered there as well.
    static func register(_ services: LedgerServices) {
        for id in [OutboxSync.refreshTaskID, OutboxSync.processingTaskID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                run(task, services: services)
            }
        }
    }

    /// Submits (or cancels) the requests for whatever is waiting now.
    static func schedule(_ services: LedgerServices) async {
        let plan = await services.outboxSync.currentPlan()
        let scheduler = BGTaskScheduler.shared
        guard let plan else {
            scheduler.cancel(taskRequestWithIdentifier: OutboxSync.processingTaskID)
            scheduler.cancel(taskRequestWithIdentifier: OutboxSync.refreshTaskID)
            return
        }
        let processing = BGProcessingTaskRequest(identifier: OutboxSync.processingTaskID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = plan.earliestBegin
        let refresh = BGAppRefreshTaskRequest(identifier: OutboxSync.refreshTaskID)
        refresh.earliestBeginDate = plan.earliestBegin
        // Fails on the simulator and when Background App Refresh is off; the
        // intent and the foreground still send, so there is nothing to surface.
        try? scheduler.submit(processing)
        try? scheduler.submit(refresh)
    }

    private static func run(_ task: BGTask, services: LedgerServices) {
        let done = Completion(task)
        let work = Task {
            let report = await services.outboxSync.runBackgroundTask()
            Telemetry.breadcrumb("sms_outbox_background", outcome: report.error == nil ? "sent" : "waiting",
                                 data: ["sent": "\(report.sent)", "remaining": "\(report.remaining)"])
            await schedule(services)
            await LocalNotifications.refreshOutbox(services)
            done.finish(success: report.error == nil)
        }
        task.expirationHandler = {
            work.cancel()
            done.finish(success: false)
        }
    }

    /// `setTaskCompleted` exactly once, from either the work or the expiry.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var task: BGTask?
        init(_ task: BGTask) { self.task = task }
        func finish(success: Bool) {
            let task = lock.withLock { () -> BGTask? in
                defer { self.task = nil }
                return self.task
            }
            task?.setTaskCompleted(success: success)
        }
    }
}

/// Reports connectivity to `OutboxSync` while the process runs, so a message
/// saved offline is sent the moment data comes back.
final class ConnectivityWatcher: Sendable {
    private let monitor = NWPathMonitor()

    init(_ services: LedgerServices) {
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task {
                if await services.outboxSync.pathChanged(satisfied: satisfied) != nil {
                    await BackgroundSync.schedule(services)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ledger.connectivity"))
    }

    deinit { monitor.cancel() }
}

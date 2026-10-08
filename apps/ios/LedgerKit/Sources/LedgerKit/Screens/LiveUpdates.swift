import Foundation

/// Follows Realtime changes for the selected profile and calls `onChange` at
/// most once per `debounce` — an SMS burst or a statement ingest touches many
/// rows, and each screen needs one refresh, not forty.
///
/// The subscription is kept alive (BACKLOG IOS-13): when the stream ends (a
/// failed subscribe, a dropped channel) it is opened again after an
/// exponential delay — 1 s, 2 s, 4 s … 60 s — for as long as the profile stays
/// selected. Changes missed while it was down are covered by one refresh of
/// every table each time it is re-opened.
@MainActor
public final class LiveUpdates {
    /// Every table the stream reports; a reconnect refreshes all of them.
    public static let tables: Set<String> = ["transactions", "sms_messages", "documents", "insights"]
    /// Reconnect delays (seconds).
    public static let reconnect = Backoff(base: 1, cap: 60)
    /// A stream that stayed open this long was healthy: the delays start over.
    public static let healthyAfter: Duration = .seconds(30)

    private var task: Task<Void, Never>?
    private let api: any LedgerAPI
    private let debounce: Duration
    private let backoff: Backoff
    private let healthyAfter: Duration

    public init(api: any LedgerAPI, debounce: Duration = .milliseconds(800),
                backoff: Backoff = LiveUpdates.reconnect, healthyAfter: Duration = LiveUpdates.healthyAfter) {
        self.api = api
        self.debounce = debounce
        self.backoff = backoff
        self.healthyAfter = healthyAfter
    }

    public var isRunning: Bool { task != nil }

    public func start(profileCode: String, onChange: @escaping @MainActor (Set<String>) async -> Void) {
        stop()
        let api = self.api
        let debounce = self.debounce
        let backoff = self.backoff
        let healthyAfter = self.healthyAfter
        task = Task { @MainActor in
            var failures = 0
            var reconnecting = false
            while !Task.isCancelled {
                let opened = ContinuousClock.now
                if reconnecting { await onChange(LiveUpdates.tables) }
                await Self.follow(api.changes(profileCode: profileCode), debounce: debounce, onChange: onChange)
                guard !Task.isCancelled else { return }
                failures = ContinuousClock.now - opened >= healthyAfter ? 1 : failures + 1
                try? await Task.sleep(for: .seconds(backoff.delay(afterAttempt: failures)))
                reconnecting = true
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private static func follow(_ stream: AsyncStream<LedgerChange>, debounce: Duration,
                               onChange: @escaping @MainActor (Set<String>) async -> Void) async {
        var pending: Set<String> = []
        var flushTask: Task<Void, Never>?
        for await change in stream {
            pending.insert(change.table)
            flushTask?.cancel()
            flushTask = Task { @MainActor in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                let tables = pending
                pending.removeAll()
                await onChange(tables)
            }
        }
    }
}

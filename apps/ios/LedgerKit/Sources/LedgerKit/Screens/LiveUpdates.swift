import Foundation

/// Follows Realtime changes for the selected profile and calls `onChange` at
/// most once per `debounce` — an SMS burst or a statement ingest touches many
/// rows, and each screen needs one refresh, not forty.
@MainActor
public final class LiveUpdates {
    private var task: Task<Void, Never>?
    private let api: any LedgerAPI
    private let debounce: Duration

    public init(api: any LedgerAPI, debounce: Duration = .milliseconds(800)) {
        self.api = api
        self.debounce = debounce
    }

    public func start(profileCode: String, onChange: @escaping @MainActor (Set<String>) async -> Void) {
        stop()
        let stream = api.changes(profileCode: profileCode)
        let debounce = self.debounce
        task = Task { @MainActor in
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

    public func stop() {
        task?.cancel()
        task = nil
    }
}

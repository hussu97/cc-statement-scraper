import Foundation

/// Drops responses a newer request superseded: a month switched twice in a
/// row, a ledger switched mid-load. Each load takes a ticket; only the newest
/// ticket may write the screen's state.
struct RequestGate<Key: Hashable & Sendable>: Sendable {
    private var counter = 0
    /// The key of the newest request.
    private(set) var requested: Key?
    /// The key whose data is on screen.
    private(set) var loaded: Key?

    /// Starts a request. `sameKey` says whether the data on screen is for the
    /// same key, so the screen may keep it visible while refreshing.
    mutating func begin(_ key: Key) -> (ticket: Int, sameKey: Bool) {
        counter += 1
        requested = key
        return (counter, loaded == key)
    }

    func isCurrent(_ ticket: Int) -> Bool { ticket == counter }

    mutating func finish(_ key: Key) { loaded = key }

    mutating func reset() {
        counter += 1
        requested = nil
        loaded = nil
    }
}

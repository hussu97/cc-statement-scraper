import Foundation
import Observation

/// Insights → Unusual spending (PAR-9, the web's Anomalies tab): `rpc('anomalies')` over a range,
/// with an owner's "This is fine" (`rpc('dismiss_anomaly')`), which keeps the charge off the list
/// for good and dismisses its "Unusually large" insight.
@MainActor
@Observable
public final class AnomaliesModel {
    public private(set) var state: LoadState<[Anomaly]> = .idle
    /// The charge being marked as fine.
    public private(set) var working: String?
    /// The last "This is fine" outcome, in words.
    public var message: String?
    private let api: any LedgerAPI
    private var gate = RequestGate<Key>()
    /// Called with the ledger after a charge is marked as fine: the server dismissed its insight
    /// too, so Overview's card and the feed reload.
    @ObservationIgnored public var onChange: (@MainActor (String) async -> Void)?

    struct Key: Hashable, Sendable {
        let profileCode: String
        let from: CalendarDay
        let to: CalendarDay
    }

    public init(api: any LedgerAPI) { self.api = api }

    /// Under the list (the web's footnote).
    public nonisolated static let footnote =
        "Each charge is compared with your purchases in the 12 months before it. Mark a charge as fine and it won't be flagged again."
    /// The empty state: a claim the server's empty answer proves.
    public nonisolated static let emptyTitle = "Nothing unusual in this range"
    public nonisolated static let emptyDetail =
        "Bank Ledger flags charges far above what you normally spend at a merchant or in a category, and large first purchases."

    /// `"Unusual spending · 3 charges"`.
    public nonisolated static func title(count: Int) -> String {
        count == 0 ? "Unusual spending" : "Unusual spending · \(count) \(count == 1 ? "charge" : "charges")"
    }

    public func load(profileCode: String, from: CalendarDay, to: CalendarDay) async {
        let key = Key(profileCode: profileCode, from: from, to: to)
        let (ticket, sameKey) = gate.begin(key)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        do {
            let rows = try await api.anomalies(profileCode: profileCode, from: from, to: to)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(key)
            state = .loaded(rows)
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    public func loadIfNeeded(profileCode: String, from: CalendarDay, to: CalendarDay) async {
        let key = Key(profileCode: profileCode, from: from, to: to)
        guard gate.requested != key || state.value == nil && !state.isLoading else { return }
        message = nil
        await load(profileCode: profileCode, from: from, to: to)
    }

    /// Realtime / foreground: the range on screen, once opened for this ledger.
    public func refresh(profileCode: String) async {
        guard let key = gate.requested, key.profileCode == profileCode else { return }
        await load(profileCode: profileCode, from: key.from, to: key.to)
    }

    /// "This is fine". Owners only (`assert_member(…, true)`): the screen shows the button to
    /// owners alone. The charge leaves the list at once; the list is then read again.
    public func markFine(_ anomaly: Anomaly, profileCode: String) async {
        working = anomaly.txnCode
        defer { working = nil }
        do {
            try await api.dismissAnomaly(profileCode: profileCode, txnCode: anomaly.txnCode)
            if case .loaded(let rows) = state {
                state = .loaded(rows.filter { $0.txnCode != anomaly.txnCode })
            }
            message = "Marked as fine. \(anomaly.name) won't be flagged again."
        } catch {
            message = "Couldn't mark it as fine: \(LoadState<Int>.message(for: error))"
        }
        await refresh(profileCode: profileCode)
        await onChange?(profileCode)
    }

    public func reset() {
        gate.reset()
        state = .idle
        working = nil
        message = nil
    }
}

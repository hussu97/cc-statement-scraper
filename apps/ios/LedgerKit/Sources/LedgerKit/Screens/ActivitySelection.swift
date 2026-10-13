import Foundation
import Observation

/// Activity's bulk select (PAR-11), with the web's semantics (`apps/web/src/routes/activity.tsx`,
/// `bulk-bar.tsx`): "Select" turns on select mode; ticking rows builds a selection; once every
/// loaded row is ticked and more match, "Select all N" makes the selection the filters
/// themselves. The bar's count and net are `activity_selection_summary`'s; Categorise and
/// Exclude / Include go through `bulk_update_transactions`. Owners only: the server asserts
/// `need_owner`, and the screen never offers select mode to a viewer (`offersSelection`).
/// CSV export stays on the web.
@MainActor
@Observable
public final class ActivitySelection {
    /// Select mode: tapping a row ticks it instead of opening it.
    public private(set) var isSelecting = false
    public private(set) var ticked: Set<String> = []
    /// "Select all N": the selection is every row matching the filters, not the ticked rows.
    public private(set) var allMatching = false
    /// The selection's figures; idle with nothing selected.
    public private(set) var summary: LoadState<ActivitySelectionSummary> = .idle
    /// The write in flight; every bulk control waits for it.
    public private(set) var busy: ActivityBulkPatch?
    /// The last action's result (`"3 transactions categorised"`), until the next one.
    public var notice: String?
    /// The last action's failure: the web toast's title and the server's reason.
    public var failure: Failure?

    public struct Failure: Sendable, Hashable {
        public let title: String
        public let message: String
    }

    private let api: any LedgerAPI
    private var gate = RequestGate<SummaryKey>()
    private struct SummaryKey: Hashable, Sendable {
        let profileCode: String
        let selection: ActivityBulkSelection
    }

    public init(api: any LedgerAPI) {
        self.api = api
    }

    // MARK: Selecting

    /// Select mode on or off ("Select" / "Done"); either way the selection starts empty.
    public func setSelecting(_ on: Bool) {
        isSelecting = on
        clear()
    }

    /// Drops the selection (the bar's ×, a new filter or ledger, a finished action).
    public func clear() {
        ticked = []
        allMatching = false
        summary = .idle
        gate.reset()
    }

    public func isSelected(_ code: String) -> Bool { allMatching || ticked.contains(code) }

    /// Ticks or unticks a row. Unticking one row of "all matching" falls back to the loaded
    /// rows minus that one, as the web does.
    public func toggle(_ code: String, loaded: [String]) {
        var next = allMatching ? Set(loaded) : ticked
        allMatching = false
        if next.contains(code) { next.remove(code) } else { next.insert(code) }
        ticked = next
    }

    /// The bar's "All": tick every loaded row.
    public func selectAllLoaded(_ loaded: [String]) {
        allMatching = false
        ticked = Set(loaded)
    }

    /// The bar's "Select all N": every row matching the filters, loaded or not.
    public func selectAllMatching() {
        allMatching = true
    }

    /// What the bulk RPCs act on for `query`'s list; nil with nothing selected.
    public func selection(for query: ActivityQuery) -> ActivityBulkSelection? {
        Self.selection(ticked: ticked, allMatching: allMatching, query: query)
    }

    // MARK: The bar

    /// `"3 selected"`, `"All 1,234 selected"` (the server's count), `"… selected"` while it loads.
    public func countText(for query: ActivityQuery) -> String? {
        guard let selection = selection(for: query) else { return nil }
        return Self.countText(selection, serverCount: summary.value?.txnCount)
    }

    /// "All": shown while some loaded rows are unticked.
    public func offersSelectAllLoaded(_ loaded: [String]) -> Bool {
        !Self.allLoadedSelected(ticked: ticked, allMatching: allMatching, loaded: loaded)
    }

    /// "Select all N": every loaded row is ticked but more rows match; nil otherwise.
    public func selectAllMatchingTotal(loaded: [String], total: Int?) -> Int? {
        Self.selectAllMatchingOffer(ticked: ticked, allMatching: allMatching, loaded: loaded, total: total)
    }

    /// The exclude button flips to "Include" when the server says every selected row is excluded.
    public var excludePatch: ActivityBulkPatch {
        .excludeFromSpend(!(summary.value?.allExcluded ?? false))
    }

    /// Exclude / Include waits for the server's figures (it decides which one it is).
    public var canExclude: Bool { busy == nil && summary.value != nil }

    // MARK: Server

    /// The selection's figures. A newer selection drops an older answer; no previous figures
    /// show under a different selection (the web waits for the new total too).
    public func loadSummary(profileCode: String, query: ActivityQuery) async {
        guard let selection = selection(for: query) else {
            summary = .idle
            return
        }
        let key = SummaryKey(profileCode: profileCode, selection: selection)
        let (ticket, same) = gate.begin(key)
        summary = .loading(previous: same ? summary.value : nil)
        do {
            let fetched = try await api.activitySelectionSummary(profileCode: profileCode, selection: selection)
            guard gate.isCurrent(ticket) else { return }
            summary = .loaded(fetched)
            gate.finish(key)
        } catch {
            guard gate.isCurrent(ticket) else { return }
            summary = .failed(LoadState<Int>.message(for: error), previous: nil)
        }
    }

    /// Runs `patch` on the selection. Returns what was acted on when the server wrote, so the
    /// list can re-read it; the selection is then cleared and `notice` says how many changed.
    /// A failure keeps the selection and sets `failure`.
    public func apply(_ patch: ActivityBulkPatch, profileCode: String,
                      query: ActivityQuery) async -> ActivityBulkSelection? {
        guard busy == nil, let selection = selection(for: query) else { return nil }
        busy = patch
        defer { busy = nil }
        do {
            let changed = try await api.bulkUpdateTransactions(profileCode: profileCode, patch: patch, selection: selection)
            notice = patch.doneMessage(changed: changed)
            clear()
            return selection
        } catch {
            failure = Failure(title: patch.failureTitle, message: LoadState<Int>.message(for: error))
            return nil
        }
    }

    // MARK: Pure

    /// Select mode is for owners (the server refuses a viewer's write) with rows to pick.
    public nonisolated static func offersSelection(canEdit: Bool, hasRows: Bool) -> Bool {
        canEdit && hasRows
    }

    nonisolated static func selection(ticked: Set<String>, allMatching: Bool,
                                      query: ActivityQuery) -> ActivityBulkSelection? {
        if allMatching { return .matching(query) }
        return ticked.isEmpty ? nil : .ticked(ticked)
    }

    nonisolated static func allLoadedSelected(ticked: Set<String>, allMatching: Bool, loaded: [String]) -> Bool {
        !loaded.isEmpty && (allMatching || loaded.allSatisfy(ticked.contains))
    }

    nonisolated static func selectAllMatchingOffer(ticked: Set<String>, allMatching: Bool, loaded: [String],
                                                   total: Int?) -> Int? {
        guard !allMatching, allLoadedSelected(ticked: ticked, allMatching: false, loaded: loaded),
              let total, total > ticked.count else { return nil }
        return total
    }

    nonisolated static func countText(_ selection: ActivityBulkSelection, serverCount: Int?) -> String {
        switch selection {
        case .codes(let codes):
            return "\(MoneyFormat.grouped(Decimal(codes.count), fractionDigits: 0)) selected"
        case .matching:
            guard let serverCount else { return "… selected" }
            return "All \(MoneyFormat.grouped(Decimal(serverCount), fractionDigits: 0)) selected"
        }
    }
}

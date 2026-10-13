import Foundation
import Observation

/// One request for a page: `offset` rows in, at most `limit` rows.
public struct PageRequest: Sendable, Hashable {
    public let offset: Int
    public let limit: Int
    public init(offset: Int, limit: Int) {
        self.offset = offset
        self.limit = limit
    }

    /// The inclusive last row index, as PostgREST's `range(from:to:)` takes it.
    public var lastIndex: Int { offset + limit - 1 }
}

/// One page as the server returned it. `total` is the exact count when the
/// endpoint gives one (PostgREST `count=exact`), else nil.
public struct ListPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let total: Int?
    public init(items: [Item], total: Int?) {
        self.items = items
        self.total = total
    }
}

/// An infinitely scrolling list: the first page, then the next one as the
/// reader nears the end. Every long list (Activity, statements, uploads,
/// reviews) uses this, so the rules live in one tested place:
///
/// - one page in flight at a time, and a page fetched for an older query or an
///   older ledger (a `reload` or `reset` since) is dropped, never appended;
/// - rows already on screen are not added twice (a new SMS shifts offsets);
/// - a failed next page leaves the rows and shows a retry row; scrolling does
///   not retry by itself;
/// - pull-to-refresh starts again from page 1; Realtime and foreground use
///   `refreshHead`, which keeps the pages the reader scrolled through.
@MainActor
@Observable
public final class Paginator<Item: Identifiable & Sendable> {
    public typealias Fetch = @Sendable (PageRequest) async throws -> ListPage<Item>

    public typealias Footer = ListFooter

    /// The one page size (CLAUDE.md §4.5).
    public nonisolated static var defaultPageSize: Int { ActivityQuery.defaultPageSize }

    public private(set) var state: LoadState<[Item]> = .idle {
        didSet { revision &+= 1 }
    }
    /// Changes whenever `state` does, so a view of the rows (Activity's day
    /// sections) is rebuilt only when they change, not on every redraw.
    public private(set) var revision = 0
    public private(set) var footer: Footer = .hidden
    /// The server's exact row count, when it gives one.
    public private(set) var total: Int?
    public let pageSize: Int
    /// Start the next page when a row this close to the end appears.
    public let prefetchDistance: Int

    private var fetch: Fetch?
    /// Server rows consumed so far: the next page's offset.
    private(set) var nextOffset = 0
    private var reachedEnd = false
    private var isLoadingMore = false
    private var generation = 0

    public init(pageSize: Int = Paginator.defaultPageSize, prefetchDistance: Int = 15) {
        self.pageSize = pageSize
        self.prefetchDistance = prefetchDistance
    }

    public var items: [Item] { state.value ?? [] }
    public var hasLoaded: Bool { state.value != nil }
    public var hasMore: Bool { hasLoaded && !reachedEnd }

    /// Loads page 1. `keepingRows` keeps the current rows on screen until the
    /// new page replaces them (pull-to-refresh); a new query passes false so
    /// the old query's rows never show under the new filters.
    public func reload(keepingRows: Bool = true, fetch newFetch: Fetch? = nil) async {
        if let newFetch { fetch = newFetch }
        guard let fetch else { return }
        generation += 1
        let gen = generation
        isLoadingMore = false   // a page in flight belongs to the old generation
        state = keepingRows ? state.startLoading() : .loading(previous: nil)
        if !keepingRows { footer = .hidden }
        do {
            let page = try await fetch(PageRequest(offset: 0, limit: pageSize))
            guard gen == generation else { return }
            nextOffset = page.items.count
            total = page.total
            reachedEnd = Self.isEnd(received: page.items.count, limit: pageSize, offset: nextOffset, total: page.total)
            let rows = Self.merge([], page.items)
            state = .loaded(rows)
            footer = Self.footer(rows: rows.count, reachedEnd: reachedEnd)
        } catch {
            guard gen == generation else { return }
            if error is CancellationError, let rows = state.value {
                state = .loaded(rows)    // a cancelled refresh leaves the list as it was
                return
            }
            state = state.fail(error)
            if state.value == nil { footer = .hidden }
        }
    }

    /// The next page. Explicit (the retry row) or from `rowAppeared`.
    public func loadMore() async {
        guard let fetch, hasLoaded, !state.isLoading, !reachedEnd, !isLoadingMore else { return }
        let gen = generation
        isLoadingMore = true
        footer = .loading
        let request = PageRequest(offset: nextOffset, limit: pageSize)
        do {
            let page = try await fetch(request)
            guard gen == generation else { return }
            isLoadingMore = false
            nextOffset += page.items.count
            total = page.total ?? total
            reachedEnd = Self.isEnd(received: page.items.count, limit: pageSize, offset: nextOffset, total: total)
            let rows = Self.merge(items, page.items)
            state = .loaded(rows)
            footer = Self.footer(rows: rows.count, reachedEnd: reachedEnd)
        } catch {
            guard gen == generation else { return }
            isLoadingMore = false
            footer = error is CancellationError ? .more : .failed(LoadState<Int>.message(for: error))
        }
    }

    /// Call from each row's `onAppear`: loads the next page when the row is
    /// within `prefetchDistance` of the end. Never retries a failed page.
    public func rowAppeared(_ id: Item.ID) async {
        guard footer == .more, items.suffix(prefetchDistance).contains(where: { $0.id == id }) else { return }
        await loadMore()
    }

    /// The footer scrolled into view: load the next page unless it failed.
    public func footerAppeared() async {
        guard footer == .more else { return }
        await loadMore()
    }

    /// Refreshes page 1 without dropping the pages below it (`mergeHead`): rows
    /// in the new first page replace their old copies, new rows go on top, and
    /// the next offset moves by the net change. With one page loaded this is a
    /// plain `reload`.
    public func refreshHead() async {
        guard let fetch, hasLoaded, nextOffset > pageSize else {
            await reload(keepingRows: true)
            return
        }
        generation += 1
        let gen = generation
        isLoadingMore = false
        state = state.startLoading()
        do {
            let page = try await fetch(PageRequest(offset: 0, limit: pageSize))
            guard gen == generation else { return }
            let old = items
            let merged = Self.mergeHead(old, page.items)
            // The server's rows moved by as many as were added or dropped above the tail.
            nextOffset = max(page.items.count, nextOffset + merged.count - old.count)
            total = page.total ?? total
            if let total { reachedEnd = nextOffset >= total }
            state = .loaded(merged)
            footer = Self.footer(rows: merged.count, reachedEnd: reachedEnd)
        } catch {
            guard gen == generation else { return }
            state = error is CancellationError ? .loaded(items) : state.fail(error)
            footer = Self.footer(rows: items.count, reachedEnd: reachedEnd)
        }
    }

    /// Replaces loaded rows in place (same position), e.g. after a recategorise.
    public func patch(_ updated: [Item]) {
        guard let rows = state.value, !updated.isEmpty else { return }
        let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        state = state.replacingValue(rows.map { byID[$0.id] ?? $0 })
    }

    /// Drops rows that no longer belong to the list (resolved, or no longer
    /// matching the filter). They have left the server's result too, so the
    /// next page's offset moves up by as many rows.
    public func remove(_ ids: Set<Item.ID>) {
        guard let rows = state.value else { return }
        let kept = rows.filter { !ids.contains($0.id) }
        let removed = rows.count - kept.count
        guard removed > 0 else { return }
        nextOffset = max(0, nextOffset - removed)
        total = total.map { max(0, $0 - removed) }
        state = state.replacingValue(kept)
        footer = Self.footer(rows: kept.count, reachedEnd: reachedEnd)
    }

    /// Forgets everything (another ledger, sign-out). Responses still in
    /// flight are dropped.
    public func reset() {
        generation += 1
        fetch = nil
        state = .idle
        footer = .hidden
        total = nil
        nextOffset = 0
        reachedEnd = false
        isLoadingMore = false
    }

    // MARK: Pure rules

    /// The last page: fewer rows than asked for, or the exact total reached.
    nonisolated static func isEnd(received: Int, limit: Int, offset: Int, total: Int?) -> Bool {
        if received == 0 { return true }
        if let total { return offset >= total }
        return received < limit
    }

    nonisolated static func footer(rows: Int, reachedEnd: Bool) -> Footer {
        rows == 0 ? .hidden : reachedEnd ? .end : .more
    }

    /// Appends a page, dropping rows already shown (and repeats within it).
    nonisolated static func merge(_ existing: [Item], _ page: [Item]) -> [Item] {
        var seen = Set(existing.map(\.id))
        var out = existing
        for item in page where seen.insert(item.id).inserted { out.append(item) }
        return out
    }

    /// A fresh first page on top, then the older rows below it. Old rows that
    /// sat above the last row the new head shares with the old list, but are
    /// not in the new head, have left the list (resolved, deleted, filtered
    /// out) and are dropped.
    nonisolated static func mergeHead(_ existing: [Item], _ head: [Item]) -> [Item] {
        let top = merge([], head)
        let topIDs = Set(top.map(\.id))
        var oldIndex: [Item.ID: Int] = [:]
        for (i, item) in existing.enumerated() { oldIndex[item.id] = i }
        let anchor = top.compactMap { oldIndex[$0.id] }.max() ?? -1
        let tail = existing.enumerated().filter { $0.offset > anchor && !topIDs.contains($0.element.id) }.map(\.element)
        return top + tail
    }
}

extension LoadState {
    /// The same state with a different value (loading/failed keep their kind).
    func replacingValue(_ value: Value) -> LoadState {
        switch self {
        case .idle, .loaded: .loaded(value)
        case .loading: .loading(previous: value)
        case .failed(let message, _): .failed(message, previous: value)
        }
    }
}

/// The row under a paged list.
public enum ListFooter: Hashable, Sendable {
    /// No rows, or the first page is still loading/failed: the list's own state shows.
    case hidden
    /// More pages exist; the next one loads as the reader nears the end.
    case more
    case loading
    case failed(String)
    /// Every row is on screen.
    case end

    /// The footer is on screen: whether to start the next page now.
    public var loadsWhenVisible: Bool { self == .more }
}

/// The end-of-list row: `"All 1,234 transactions"`.
public enum ListEnd {
    public static func message(count: Int, total: Int? = nil, singular: String, plural: String) -> String {
        let n = total.map { max($0, count) } ?? count
        if n == 1 { return "That's the only \(singular)" }
        return "All \(MoneyFormat.grouped(Decimal(n), fractionDigits: 0)) \(plural)"
    }
}

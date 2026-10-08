import Foundation
import Testing
@testable import LedgerKit

struct Row: Identifiable, Sendable, Hashable {
    let id: String
    var label = ""
}

func rows(_ range: Range<Int>, prefix: String = "r") -> [Row] { range.map { Row(id: "\(prefix)\($0)") } }

/// A server table `fetch` pages through; tests change it between calls.
final class RowTable: @unchecked Sendable {
    private let lock = NSLock()
    private var _rows: [Row]
    private var _requests: [PageRequest] = []
    private var _failNext: LedgerAPIError?
    let reportsTotal: Bool

    init(_ rows: [Row], reportsTotal: Bool = true) {
        _rows = rows
        self.reportsTotal = reportsTotal
    }

    var rows: [Row] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }
    var requests: [PageRequest] { lock.withLock { _requests } }
    func failNext(_ error: LedgerAPIError) { lock.withLock { _failNext = error } }

    var fetch: Paginator<Row>.Fetch {
        { [self] request in
            try lock.withLock {
                _requests.append(request)
                if let error = _failNext {
                    _failNext = nil
                    throw error
                }
                let page = Array(_rows.dropFirst(request.offset).prefix(request.limit))
                return ListPage(items: page, total: reportsTotal ? _rows.count : nil)
            }
        }
    }
}

/// Fetches that wait until the test answers them, to drive interleavings.
final class HeldFetches: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(request: PageRequest, continuation: CheckedContinuation<ListPage<Row>, any Error>)] = []
    private var _requests: [PageRequest] = []

    var requests: [PageRequest] { lock.withLock { _requests } }

    var fetch: Paginator<Row>.Fetch {
        { [self] request in
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    _requests.append(request)
                    waiting.append((request, continuation))
                }
            }
        }
    }

    /// Waits (yielding) until `n` requests have arrived in total.
    func arrived(_ n: Int) async {
        for _ in 0..<10_000 where requests.count < n { await Task.yield() }
    }

    /// Answers the oldest waiting request with `rows`.
    func answer(_ rows: [Row], total: Int?) {
        let next = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        next?.continuation.resume(returning: ListPage(items: rows, total: total))
    }
}

@MainActor
@Suite("Paginator: infinite scroll")
struct PaginatorTests {
    @Test("pages load as the reader nears the end, then the list says it has everything")
    func pagesToTheEnd() async {
        let table = RowTable(rows(0..<250))
        let list = Paginator<Row>(pageSize: 100, prefetchDistance: 15)
        await list.reload(fetch: table.fetch)
        #expect(list.items.count == 100)
        #expect(list.footer == .more)
        #expect(list.total == 250)

        await list.rowAppeared("r50")            // far from the end: nothing
        #expect(table.requests.count == 1)
        await list.rowAppeared("r85")            // within 15 of the end
        #expect(table.requests.last == PageRequest(offset: 100, limit: 100))
        #expect(list.items.count == 200)

        await list.footerAppeared()
        #expect(list.items.map(\.id) == rows(0..<250).map(\.id))
        #expect(list.footer == .end)
        await list.loadMore()                    // at the end: no request
        #expect(table.requests.count == 3)
    }

    @Test("without a count, a short page is the last one")
    func endWithoutTotal() async {
        let table = RowTable(rows(0..<150), reportsTotal: false)
        let list = Paginator<Row>(pageSize: 100)
        await list.reload(fetch: table.fetch)
        #expect(list.footer == .more)
        await list.loadMore()
        #expect(list.items.count == 150)
        #expect(list.footer == .end)
    }

    @Test("an empty list shows no footer; one page that is everything shows the end")
    func emptyAndSinglePage() async {
        let list = Paginator<Row>(pageSize: 100)
        await list.reload(fetch: RowTable([]).fetch)
        #expect(list.items.isEmpty && list.footer == .hidden)
        await list.reload(fetch: RowTable(rows(0..<3)).fetch)
        #expect(list.footer == .end)
    }

    @Test("two near-end rows appearing together start one request, not two")
    func oneRequestAtATime() async {
        let held = HeldFetches()
        let list = Paginator<Row>(pageSize: 10, prefetchDistance: 5)
        async let first: Void = list.reload(fetch: held.fetch)
        await held.arrived(1)
        held.answer(rows(0..<10), total: 30)
        await first

        async let a: Void = list.rowAppeared("r8")
        async let b: Void = list.rowAppeared("r9")
        async let c: Void = list.loadMore()
        await held.arrived(2)
        for _ in 0..<100 { await Task.yield() }
        #expect(held.requests.count == 2)        // page 1 + exactly one next page
        #expect(list.footer == .loading)
        held.answer(rows(10..<20), total: 30)
        _ = await (a, b, c)
        #expect(list.items.count == 20)
        #expect(Set(list.items.map(\.id)).count == 20)
    }

    @Test("a page fetched before a reload is dropped, never appended to the new list")
    func stalePageDropped() async {
        let held = HeldFetches()
        let list = Paginator<Row>(pageSize: 10)
        async let first: Void = list.reload(fetch: held.fetch)
        await held.arrived(1)
        held.answer(rows(0..<10), total: 30)
        await first

        async let more: Void = list.loadMore()            // old query, page 2
        await held.arrived(2)
        async let reload: Void = list.reload(keepingRows: false, fetch: held.fetch)   // new query
        await held.arrived(3)
        held.answer(rows(10..<20), total: 30)             // the old page 2 arrives late
        held.answer(rows(0..<5, prefix: "n"), total: 5)   // the new query's page 1
        _ = await (more, reload)
        #expect(list.items.map(\.id) == ["n0", "n1", "n2", "n3", "n4"])
        #expect(list.footer == .end)
    }

    @Test("a new query never shows the old rows; pull-to-refresh keeps them until page 1 arrives")
    func keepingRows() async {
        let held = HeldFetches()
        let list = Paginator<Row>(pageSize: 10)
        async let first: Void = list.reload(fetch: held.fetch)
        await held.arrived(1)
        held.answer(rows(0..<10), total: 10)
        await first

        async let refresh: Void = list.reload(keepingRows: true)
        await held.arrived(2)
        #expect(list.items.count == 10 && list.state.isLoading)
        held.answer(rows(0..<10), total: 10)
        await refresh

        async let newQuery: Void = list.reload(keepingRows: false, fetch: held.fetch)
        await held.arrived(3)
        #expect(list.items.isEmpty && list.state.isLoading)
        held.answer([], total: 0)
        await newQuery
    }

    @Test("pull-to-refresh starts again from page 1")
    func refreshResetsToPageOne() async {
        let table = RowTable(rows(0..<300))
        let list = Paginator<Row>(pageSize: 100)
        await list.reload(fetch: table.fetch)
        await list.loadMore()
        await list.loadMore()
        #expect(list.items.count == 300)
        await list.reload()
        #expect(list.items.count == 100)
        #expect(table.requests.last == PageRequest(offset: 0, limit: 100))
        await list.loadMore()
        #expect(table.requests.last == PageRequest(offset: 100, limit: 100))
    }

    @Test("a failed next page keeps the rows, shows a retry row, and scrolling does not retry")
    func failedPageRetries() async {
        let table = RowTable(rows(0..<150))
        let list = Paginator<Row>(pageSize: 100)
        await list.reload(fetch: table.fetch)
        table.failNext(.network("-1009"))
        await list.loadMore()
        #expect(list.items.count == 100)
        #expect(list.footer == .failed("No connection to Ledger."))
        await list.rowAppeared("r99")
        await list.footerAppeared()
        #expect(table.requests.count == 2)       // no automatic retry
        await list.loadMore()                    // the retry button
        #expect(table.requests.last == PageRequest(offset: 100, limit: 100))
        #expect(list.items.count == 150 && list.footer == .end)
    }

    @Test("rows already shown are not added twice when new rows shift the offsets")
    func noDuplicatesWhenOffsetsShift() async {
        let table = RowTable(rows(0..<200))
        let list = Paginator<Row>(pageSize: 100)
        await list.reload(fetch: table.fetch)
        table.rows = rows(0..<3, prefix: "new") + table.rows   // three SMS arrive
        await list.loadMore()                    // r97…r196: the first three are already shown
        #expect(list.items.count == 197)
        #expect(Set(list.items.map(\.id)).count == 197)
        #expect(list.footer == .more)
        await list.loadMore()
        #expect(list.items.map(\.id) == rows(0..<200).map(\.id))
        #expect(!list.items.contains { $0.id.hasPrefix("new") })   // they come with a refresh
    }

    @Test("Realtime refresh keeps the scrolled pages: new rows on top, removed rows gone, offsets follow")
    func refreshHeadKeepsPages() async {
        let table = RowTable(rows(0..<300))
        let list = Paginator<Row>(pageSize: 100)
        await list.reload(fetch: table.fetch)
        await list.loadMore()
        #expect(list.items.count == 200)

        var server = table.rows
        server.remove(at: 5)                                   // r5 resolved elsewhere
        server[0].label = "edited"
        table.rows = rows(0..<2, prefix: "new") + server       // two new rows
        await list.refreshHead()
        #expect(list.items.count == 201)
        #expect(list.items.prefix(3).map(\.id) == ["new0", "new1", "r0"])
        #expect(list.items[2].label == "edited")
        #expect(!list.items.contains { $0.id == "r5" })
        #expect(list.items.last?.id == "r199")
        await list.loadMore()
        #expect(table.requests.last == PageRequest(offset: 201, limit: 100))
        #expect(list.items.count == 301)
        #expect(Set(list.items.map(\.id)).count == 301)
        #expect(list.footer == .end)
    }

    @Test("with one page loaded, a Realtime refresh is a plain reload")
    func refreshHeadSinglePage() async {
        let table = RowTable(rows(0..<50))
        let list = Paginator<Row>(pageSize: 100)
        await list.reload(fetch: table.fetch)
        table.rows = rows(0..<1, prefix: "new") + table.rows.dropLast(10)
        await list.refreshHead()
        #expect(list.items.count == 41 && list.items.first?.id == "new0")
    }

    @Test("an edited row is patched where it is; a row that left the list moves the next offset")
    func patchAndRemove() async {
        let table = RowTable(rows(0..<250))
        let list = Paginator<Row>(pageSize: 100)
        await list.reload(fetch: table.fetch)
        await list.loadMore()
        list.patch([Row(id: "r150", label: "Groceries")])
        #expect(list.items.count == 200 && list.items[150].label == "Groceries")

        list.remove(["r150", "r151"])
        table.rows.removeAll { $0.id == "r150" || $0.id == "r151" }
        #expect(list.items.count == 198 && list.total == 248)
        await list.loadMore()
        #expect(table.requests.last == PageRequest(offset: 198, limit: 100))
        #expect(list.items.count == 248 && Set(list.items.map(\.id)).count == 248)
    }

    @Test("reset drops a first page still in flight (another ledger)")
    func resetDropsInFlight() async {
        let held = HeldFetches()
        let list = Paginator<Row>(pageSize: 10)
        async let first: Void = list.reload(fetch: held.fetch)
        await held.arrived(1)
        list.reset()
        held.answer(rows(0..<10), total: 10)
        await first
        #expect(list.state.value == nil && list.footer == .hidden)
    }

    @Test("end-of-list wording")
    func endWording() {
        #expect(ListEnd.message(count: 1, singular: "transaction", plural: "transactions") == "That's the only transaction")
        #expect(ListEnd.message(count: 1234, total: 1234, singular: "transaction", plural: "transactions")
                == "All 1,234 transactions")
        #expect(ListEnd.message(count: 12, singular: "review", plural: "reviews") == "All 12 reviews")
    }
}

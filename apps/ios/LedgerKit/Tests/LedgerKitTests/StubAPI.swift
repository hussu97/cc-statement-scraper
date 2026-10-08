import Foundation
@testable import LedgerKit

/// A scripted `LedgerAPI`. Only the SMS path is configurable; everything else
/// returns empty data, which is all the tests that use it need.
final class StubAPI: LedgerAPI, @unchecked Sendable {
    enum IngestBehaviour {
        case succeed(status: String)
        case fail(LedgerAPIError)
    }

    private let lock = NSLock()
    private var _behaviour: IngestBehaviour
    private var _calls: [(profile: String, messages: [SMSPayload])] = []

    init(_ behaviour: IngestBehaviour = .succeed(status: "new")) {
        _behaviour = behaviour
    }

    var behaviour: IngestBehaviour {
        get { lock.withLock { _behaviour } }
        set { lock.withLock { _behaviour = newValue } }
    }

    var calls: [(profile: String, messages: [SMSPayload])] { lock.withLock { _calls } }
    var sentMessageCount: Int { calls.reduce(0) { $0 + $1.messages.count } }

    func ingestSMS(profileCode: String, messages: [SMSPayload]) async throws -> [SMSIngestResult] {
        let behaviour: IngestBehaviour = lock.withLock {
            _calls.append((profileCode, messages))
            return _behaviour
        }
        switch behaviour {
        case .succeed(let status):
            return messages.map {
                SMSIngestResult(clientMsgId: $0.clientMsgId.uuidString.lowercased(), smsCode: "sms_x", status: status, txnCode: nil)
            }
        case .fail(let error):
            throw error
        }
    }

    // MARK: Unused by these tests

    func profiles() async throws -> [LedgerProfile] { [] }
    func memberships() async throws -> [ProfileMembership] { [] }
    func createProfile(key: String, name: String) async throws -> String { "prf_x" }
    func overview(profileCode: String, month: CalendarDay?) async throws -> Overview { throw LedgerAPIError.noProfile }
    func categoryBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [CategorySpend] { [] }
    func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain, group: SpendGroup) async throws -> [SpendPoint] { [] }
    func merchantLeaderboard(profileCode: String, from: CalendarDay, to: CalendarDay, limit: Int) async throws -> [MerchantSpend] { [] }
    func statementCycles(profileCode: String, limit: Int) async throws -> [StatementCycle] { [] }
    func budgetStatus(profileCode: String, month: CalendarDay?) async throws -> [BudgetStatus] { [] }
    func recurringList(profileCode: String) async throws -> [RecurringCharge] { [] }
    func filterMeta(profileCode: String) async throws -> FilterMeta {
        FilterMeta(accounts: [], cards: [], categories: [], banks: [], dateRange: nil)
    }
    func transactions(profileCode: String, query: ActivityQuery) async throws -> TransactionPage { .init(rows: [], total: 0) }
    func insights(profileCode: String) async throws -> [Insight] { [] }
    func dismissInsight(insightCode: String) async throws {}
    func documents(profileCode: String, limit: Int) async throws -> [DocumentRecord] { [] }
    func setTransactionCategory(txnCode: String, categoryCode: String, applyToMerchant: Bool) async throws {}
    func uploadStatements(profileCode: String, files: [UploadFile]) async throws -> UploadResponse { .init(uploads: []) }
    func changes(profileCode: String) -> AsyncStream<LedgerChange> { AsyncStream { $0.finish() } }
}

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_791_436_364)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

func temporaryOutboxURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ledger-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("sms-outbox.json")
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

import Testing

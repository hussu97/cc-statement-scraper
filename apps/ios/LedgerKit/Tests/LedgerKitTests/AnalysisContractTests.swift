import Foundation
import Testing
@testable import LedgerKit

/// PAR-12's wire contract: each analysis RPC's `returns table (…)` columns, read from the newest
/// migration that defines it, are exactly the keys of its fixture, and the fixtures decode into
/// the app's rows with exact decimals.
@Suite("Analysis RPCs — contract with the SQL and decoding")
struct AnalysisContractTests {
    /// `…/apps/ios/LedgerKit/Tests/LedgerKitTests/<this file>` → the repository root.
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    struct ContractMissing: Error, CustomStringConvertible { let description: String }

    /// The column names of `public.<name>`'s `returns table (…)` in the newest migration defining it.
    static func returnedColumns(of name: String) throws -> [String] {
        let dir = repoRoot.appending(path: "supabase/migrations")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".sql") }.sorted()
        // A definition, not a grant or comment naming it; its `returns table` comes before its body.
        let marker = "create or replace function public.\(name)("
        for file in files.reversed() {
            let sql = try String(contentsOf: dir.appending(path: file), encoding: .utf8)
            guard let def = sql.range(of: marker, options: [.backwards, .caseInsensitive]) else { continue }
            let body = sql.range(of: "$$", range: def.upperBound..<sql.endIndex)?.lowerBound ?? sql.endIndex
            guard let open = sql.range(of: "returns table (", range: def.upperBound..<body) else {
                throw ContractMissing(description: "public.\(name) in \(file) no longer returns a table")
            }
            var depth = 1
            var part = ""
            var columns: [String] = []
            for ch in sql[open.upperBound...] {
                if ch == "(" { depth += 1 }
                if ch == ")" { depth -= 1 }
                if depth == 0 || ch == "," && depth == 1 {
                    if let column = part.split(whereSeparator: \.isWhitespace).first { columns.append(String(column)) }
                    part = ""
                    if depth == 0 { break }
                    continue
                }
                part.append(ch)
            }
            return columns
        }
        throw ContractMissing(description: "no migration defines public.\(name) with returns table")
    }

    static func fixtureKeys(_ name: String) throws -> [Set<String>] {
        let rows = try #require(try JSONSerialization.jsonObject(with: try fixture(name)) as? [[String: Any]])
        return rows.map { Set($0.keys) }
    }

    @Test("fixture keys are the SQL's returned columns", arguments: [
        "daily_spend", "hour_weekday_pattern", "yoy_compare", "fx_spend", "recurring_list", "cash_flow",
    ])
    func fixturesMatchSQL(rpc: String) throws {
        let columns = try Self.returnedColumns(of: rpc)
        #expect(!columns.isEmpty)
        for keys in try Self.fixtureKeys(rpc) {
            #expect(keys == Set(columns), "\(rpc): fixture \(keys.sorted()) vs SQL \(columns)")
        }
    }

    @Test("the parser reads a known definition")
    func parserSelfTest() throws {
        #expect(try Self.returnedColumns(of: "daily_spend") == ["day", "amount", "txn_count"])
        #expect(try Self.returnedColumns(of: "yoy_compare") == ["month", "this_year", "last_year"])
    }

    @Test("daily_spend decodes days and exact amounts")
    func daily() throws {
        let rows = try LedgerJSON.decode([DailySpend].self, from: try fixture("daily_spend"))
        #expect(rows.count == 6)
        #expect(rows[1] == DailySpend(day: CalendarDay(year: 2026, month: 9, day: 30), amount: Decimal(string: "1240.75")!, txnCount: 4))
        #expect(rows[5].amount == -45)
    }

    @Test("hour_weekday_pattern decodes ISO weekdays and hours")
    func hours() throws {
        let rows = try LedgerJSON.decode([HourWeekdaySpend].self, from: try fixture("hour_weekday_pattern"))
        #expect(rows.map(\.dow) == [1, 1, 5, 7])
        #expect(rows[2].amount == Decimal(string: "905.25")!)
    }

    @Test("yoy_compare decodes twelve months")
    func yoy() throws {
        let rows = try LedgerJSON.decode([YearOverYearMonth].self, from: try fixture("yoy_compare"))
        #expect(rows.map(\.month) == Array(1...12))
        #expect(rows[5].thisYear == Decimal(string: "9800.55")!)
        #expect(rows[11].thisYear == 0)
    }

    @Test("fx_spend decodes rates, shares and a null rate")
    func fx() throws {
        let rows = try LedgerJSON.decode([FxSpend].self, from: try fixture("fx_spend"))
        #expect(rows.map(\.currency) == ["USD", "EUR", "JPY", "GBP"])
        #expect(rows[0].impliedRate == Decimal(string: "3.673")!)
        #expect(rows[1].estimatedShare == Decimal(string: "0.4")!)
        #expect(rows[3].impliedRate == nil)
    }

    @Test("recurring_list decodes every status")
    func recurring() throws {
        let rows = try LedgerJSON.decode([RecurringCharge].self, from: try fixture("recurring_list"))
        #expect(rows.map(\.status) == ["active", "active", "dismissed", "ended"])
        #expect(rows[0].annualCost == 540)
        #expect(rows[1].categoryName == nil)
    }

    @Test("money also decodes from the string form")
    func stringMoney() throws {
        let rows = try LedgerJSON.decode([FxSpend].self, from: Data("""
        [{"currency": "USD", "amount_original": "10.10", "amount_aed": "37.10", "txn_count": 1,
          "implied_rate": "3.673267", "estimated_share": "0.000"}]
        """.utf8))
        #expect(rows[0].amountAed == Decimal(string: "37.10")!)
        #expect(rows[0].impliedRate == Decimal(string: "3.673267")!)
    }
}

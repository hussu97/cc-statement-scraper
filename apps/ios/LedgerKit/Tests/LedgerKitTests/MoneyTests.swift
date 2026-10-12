import Foundation
import Testing
@testable import LedgerKit

@Suite("Money decoding — numbers and strings land in Decimal exactly")
struct DecimalDecodingTests {
    struct Row: Decodable {
        let a: Decimal
        let b: Decimal
        let c: Decimal?
    }

    @Test("JSON numbers 0.1 + 0.2 == 0.3 exactly (no Double on the way)")
    func numbersAreExact() throws {
        let row = try LedgerJSON.decode(Row.self, from: Data(#"{"a": 0.1, "b": 0.2, "c": null}"#.utf8))
        #expect(row.a + row.b == Decimal(string: "0.3")!)
        #expect(MoneyFormat.plain(row.a + row.b) == "0.3")
        #expect(row.c == nil)
    }

    @Test("decimal strings 0.1 + 0.2 == 0.3 exactly")
    func stringsAreExact() throws {
        let row = try LedgerJSON.decode(Row.self, from: Data(#"{"a": "0.1", "b": "0.2"}"#.utf8))
        #expect(row.a + row.b == Decimal(string: "0.3")!)
    }

    @Test("1234567.89 round-trips as number and as string", arguments: [
        #"{"a": 1234567.89, "b": "1234567.89"}"#,
        #"{"a": "1234567.89", "b": 1234567.89}"#,
    ])
    func largeValueRoundTrips(json: String) throws {
        let row = try LedgerJSON.decode(Row.self, from: Data(json.utf8))
        #expect(row.a == row.b)
        #expect(MoneyFormat.plain(row.a) == "1234567.89")
        #expect(MoneyFormat.aed(row.a) == "AED 1,234,567.89")
        // The value a Double would have produced differs in the 10th significant digit
        // for larger numerics; numeric(14,2)'s maximum must also be exact.
        let max = try LedgerJSON.decode(Row.self, from: Data(#"{"a": 999999999999.99, "b": "999999999999.99"}"#.utf8))
        #expect(MoneyFormat.plain(max.a) == "999999999999.99")
        #expect(max.a == max.b)
    }

    @Test("FX rates keep 8 decimal places")
    func fxRate() throws {
        let row = try LedgerJSON.decode(Row.self, from: Data(#"{"a": 3.67250001, "b": "0.27229408"}"#.utf8))
        #expect(MoneyFormat.plain(row.a) == "3.67250001")
        #expect(MoneyFormat.plain(row.b) == "0.27229408")
    }

    @Test("strict parsing rejects a numeric prefix with junk", arguments: ["5O", "12,50", "", " ", "1.", ".5", "abc", "1.2.3"])
    func rejectsJunk(raw: String) {
        #expect(LedgerDecimal.parse(raw) == nil)
    }

    @Test("strict parsing accepts Postgres numeric text", arguments: ["0", "-12.50", "1234567.89", "+3", "1e3", "0.00000001"])
    func acceptsNumeric(raw: String) {
        #expect(LedgerDecimal.parse(raw) != nil)
    }

    @Test("a malformed money string is a decoding error, not a silent zero")
    func malformedStringThrows() {
        #expect(throws: DecodingError.self) {
            try LedgerJSON.decode(Row.self, from: Data(#"{"a": "12abc", "b": 1}"#.utf8))
        }
    }

    @Test("DecimalValue in arrays (generic decode path)")
    func arrayOfDecimals() throws {
        let values = try LedgerJSON.decode([DecimalValue].self, from: Data(#"[0.1, "0.2", 1234567.89]"#.utf8))
        #expect(values.map(\.value).reduce(0, +) == Decimal(string: "1234568.19")!)
    }
}

@Suite("Money formatting")
struct MoneyFormatTests {
    @Test func aedGrouping() {
        #expect(MoneyFormat.aed(Decimal(string: "0")!) == "AED 0.00")
        #expect(MoneyFormat.aed(Decimal(string: "5")!) == "AED 5.00")
        #expect(MoneyFormat.aed(Decimal(string: "999.9")!) == "AED 999.90")
        #expect(MoneyFormat.aed(Decimal(string: "1000")!) == "AED 1,000.00")
        #expect(MoneyFormat.aed(Decimal(string: "-1234.5")!) == "AED -1,234.50")
    }

    @Test("half-up rounding, exact in base 10")
    func rounding() {
        #expect(MoneyFormat.aed(Decimal(string: "2.345")!) == "AED 2.35")
        #expect(MoneyFormat.aed(Decimal(string: "2.344")!) == "AED 2.34")
        #expect(MoneyFormat.hero(Decimal(string: "12499.5")!) == "12,500")
        #expect(MoneyFormat.hero(Decimal(string: "1234567.89")!) == "1,234,568")
    }

    @Test("the hero amount is spoken in dirhams, rounded like the hero")
    func spokenDirhams() {
        #expect(MoneyFormat.spokenDirhams(Decimal(string: "860.20")!) == "860 dirhams")
        #expect(MoneyFormat.spokenDirhams(Decimal(string: "1234567.89")!) == "1,234,568 dirhams")
        #expect(MoneyFormat.spokenDirhams(Decimal(string: "0.6")!) == "1 dirham")
        #expect(MoneyFormat.spokenDirhams(0) == "0 dirhams")
        #expect(MoneyFormat.spokenDirhams(Decimal(string: "-50")!) == "minus 50 dirhams")
    }

    @Test("original currency uses ISO minor units")
    func otherCurrencies() {
        #expect(MoneyFormat.amount(Decimal(string: "12")!, currency: "usd") == "USD 12.00")
        #expect(MoneyFormat.amount(Decimal(string: "1200")!, currency: "JPY") == "JPY 1,200")
        #expect(MoneyFormat.amount(Decimal(string: "1.5")!, currency: "KWD") == "KWD 1.500")
    }

    @Test("compact keeps one decimal so 12.5k and 13.5k stay distinct")
    func compact() {
        #expect(MoneyFormat.compact(Decimal(string: "950")!) == "950")
        #expect(MoneyFormat.compact(Decimal(string: "12500")!) == "12.5k")
        #expect(MoneyFormat.compact(Decimal(string: "13500")!) == "13.5k")
        #expect(MoneyFormat.compact(Decimal(string: "2000")!) == "2k")
        #expect(MoneyFormat.compact(Decimal(string: "1250000")!) == "1.3M")
        #expect(MoneyFormat.compact(Decimal(string: "-4200")!) == "-4.2k")
    }

    @Test func percent() {
        #expect(MoneyFormat.percent(Decimal(string: "0.4213")!) == "42%")
        #expect(MoneyFormat.percent(Decimal(string: "0.875")!, fractionDigits: 1) == "87.5%")
        #expect(MoneyFormat.percent(Decimal(string: "0.005")!) == "1%")
    }

    @Test("DecimalValue encodes as the plain wire string")
    func encodesAsString() throws {
        let data = try JSONEncoder().encode([DecimalValue(Decimal(string: "1234567.89")!)])
        #expect(String(decoding: data, as: UTF8.self) == #"["1234567.89"]"#)
    }
}

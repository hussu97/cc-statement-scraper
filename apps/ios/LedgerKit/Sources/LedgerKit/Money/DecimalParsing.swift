import Foundation

// Money crosses the wire two ways, and both must land in `Decimal` exactly:
//
// * PostgREST table/view/set-returning reads send `numeric` as a JSON *number*
//   (`1234567.89`). Swift's `JSONDecoder` (swift-foundation, iOS 17+/macOS 14+)
//   special-cases `Decimal` and parses the number token's digits directly, so no
//   binary float is involved. `DecimalParsingTests` pins that behaviour.
// * jsonb RPC payloads (`overview`, `ingest_sms`, recon checks) send money as a
//   decimal *string* (`"1234567.89"`), because the SQL casts `::text`.
//
// Synthesised `Codable` only reads the number form, so the overloads below add
// the string form for every statically-resolved `Decimal` property. A decimal
// nested in a dictionary or array is decoded generically and skips them; wrap it
// in `DecimalValue` instead.

/// Strict decimal parsing. `Decimal(string:)` accepts a numeric *prefix* and
/// ignores the rest (`"5O"` → 5), which is never acceptable for money.
public enum LedgerDecimal {
    private static let posix = Locale(identifier: "en_US_POSIX")

    public static func parse(_ raw: String) -> Decimal? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard isPlainDecimal(s) else { return nil }
        return Decimal(string: s, locale: posix)
    }

    /// `-?digits(.digits)?(e±digits)?` — the shapes Postgres `numeric::text` and
    /// JSON numbers produce.
    static func isPlainDecimal(_ s: String) -> Bool {
        var chars = Substring(s)
        if chars.first == "-" || chars.first == "+" { chars = chars.dropFirst() }
        let mantissa = chars.prefix { $0 != "e" && $0 != "E" }
        let exponent = chars.dropFirst(mantissa.count)
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              !parts[0].isEmpty, parts[0].allSatisfy(\.isASCIIDigit) else { return false }
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(\.isASCIIDigit) { return false }
        if !exponent.isEmpty {
            var exp = exponent.dropFirst()
            if exp.first == "-" || exp.first == "+" { exp = exp.dropFirst() }
            return !exp.isEmpty && exp.allSatisfy(\.isASCIIDigit)
        }
        return true
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// A `Decimal` that may arrive as a JSON string or a JSON number.
public struct DecimalValue: Codable, Hashable, Sendable {
    public let value: Decimal

    public init(_ value: Decimal) { self.value = value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard let decimal = LedgerDecimal.parse(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "'\(string)' is not a decimal number")
            }
            value = decimal
            return
        }
        // JSONDecoder reads the number token's digits straight into Decimal.
        value = try container.decode(Decimal.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(MoneyFormat.plain(value))
    }
}

extension KeyedDecodingContainer {
    public func decode(_ type: Decimal.Type, forKey key: Key) throws -> Decimal {
        try decode(DecimalValue.self, forKey: key).value
    }

    public func decodeIfPresent(_ type: Decimal.Type, forKey key: Key) throws -> Decimal? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decode(DecimalValue.self, forKey: key).value
    }
}

import Foundation

/// Money formatting done on the `Decimal` itself. `NumberFormatter` converts to
/// a double internally for fractional values, so it is not used for money.
/// Output is always ASCII digits with `,` grouping, whatever the device locale.
public enum MoneyFormat {
    /// ISO 4217 minor units for the currencies that differ from 2.
    static let minorUnits: [String: Int] = [
        "JPY": 0, "KRW": 0, "VND": 0, "CLP": 0, "ISK": 0, "UGX": 0,
        "BHD": 3, "KWD": 3, "OMR": 3, "JOD": 3, "TND": 3, "IQD": 3, "LYD": 3,
    ]

    public static func fractionDigits(for currency: String) -> Int {
        minorUnits[currency.uppercased()] ?? 2
    }

    /// `"AED 1,234.50"`.
    public static func aed(_ value: Decimal, fractionDigits: Int = 2) -> String {
        amount(value, currency: "AED", fractionDigits: fractionDigits)
    }

    /// `"USD 12.00"`, `"JPY 1,200"`.
    public static func amount(_ value: Decimal, currency: String, fractionDigits: Int? = nil) -> String {
        let digits = fractionDigits ?? Self.fractionDigits(for: currency)
        return "\(currency.uppercased()) \(grouped(value, fractionDigits: digits))"
    }

    /// The hero number: no currency code, whole dirhams. `"12,345"`.
    public static func hero(_ value: Decimal) -> String {
        grouped(value, fractionDigits: 0)
    }

    /// Short axis/chip labels: `"950"`, `"12.5k"`, `"1.2M"`. One decimal is kept
    /// so 12,500 and 13,500 do not both become "13k" through half-even rounding.
    public static func compact(_ value: Decimal) -> String {
        let magnitude = value < 0 ? -value : value
        let sign = value < 0 ? "-" : ""
        if magnitude >= 1_000_000 {
            return sign + trimmed(rounded(magnitude / 1_000_000, scale: 1)) + "M"
        }
        if magnitude >= 1_000 {
            return sign + trimmed(rounded(magnitude / 1_000, scale: 1)) + "k"
        }
        return sign + grouped(magnitude, fractionDigits: 0)
    }

    /// A ratio from the server (`0.4213`) as `"42%"`; `fractionDigits` adds precision.
    public static func percent(_ ratio: Decimal, fractionDigits: Int = 0) -> String {
        grouped(ratio * 100, fractionDigits: fractionDigits) + "%"
    }

    /// The canonical wire form: plain digits, `.` separator, no grouping.
    public static func plain(_ value: Decimal) -> String {
        var v = value
        return NSDecimalString(&v, Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - Core

    /// Half-up (away from zero) rounding to `scale` places, exact in base 10.
    public static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }

    /// `1234567.8` → `"1,234,567.80"`.
    public static func grouped(_ value: Decimal, fractionDigits: Int) -> String {
        let r = rounded(value, scale: fractionDigits)
        var text = plain(r < 0 ? -r : r)
        let negative = r < 0
        if text.hasPrefix("-") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts[0])
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        if fraction.count < fractionDigits {
            fraction += String(repeating: "0", count: fractionDigits - fraction.count)
        }
        var groupedInt = ""
        for (i, ch) in integer.reversed().enumerated() {
            if i > 0, i % 3 == 0 { groupedInt.append(",") }
            groupedInt.append(ch)
        }
        let body = String(groupedInt.reversed()) + (fractionDigits > 0 ? "." + fraction : "")
        return negative ? "-" + body : body
    }

    private static func trimmed(_ value: Decimal) -> String {
        var s = grouped(value, fractionDigits: 1)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }
}

extension Decimal {
    /// For sizing chart marks only. Money never passes through a binary float;
    /// written via `NSDecimalNumber` explicitly so a bulk edit cannot turn it
    /// into a self-referencing property.
    public var chartValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

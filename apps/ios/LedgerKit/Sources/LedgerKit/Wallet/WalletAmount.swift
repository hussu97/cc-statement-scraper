import Foundation
import Synchronization

/// Where "Log Card Payment" takes the amount and its currency from.
///
/// A Shortcuts Transaction automation hands over the Wallet transaction's
/// Amount as the device formats it: `"AED 12.50"`, `"€4.20"`, `"$6.25"`,
/// `"12,50 €"`. The intent reads it as text, so the currency comes with it (an
/// `IntentCurrencyAmount` parameter would bind only the number and take the
/// currency from a picker fixed in the automation). Only when the text has no
/// currency marker at all does the shortcut's optional *Currency if missing*
/// apply. A marker that names no currency, or several (`$` on an en_GB phone),
/// refuses the payment: the fallback would file it in a currency the text
/// contradicts. Nothing is ever filed in a guessed currency.
public enum WalletAmount {
    public enum Source: String, Sendable, Equatable {
        /// The currency was read from the Amount text.
        case text
        /// The Amount text had none; *Currency if missing* supplied it.
        case fallbackCurrency
    }

    public struct Resolved: Sendable, Equatable {
        public let amount: Decimal
        public let currency: String
        public let source: Source
    }

    /// Picks the amount and currency for one payment, or the problem that stops it.
    /// - Parameters:
    ///   - text: the intent's Amount (Shortcut Input → Amount), as text.
    ///   - fallbackCurrency: the shortcut's optional *Currency if missing*.
    ///   - locale: how the device formats amounts (decides `$` and `1,234`).
    public static func resolve(text: String?, fallbackCurrency: String?,
                               locale: Locale = .current) -> Result<Resolved, WalletCapture.Problem> {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingAmount)
        }
        guard let parsed = WalletAmountText.parse(text, locale: locale) else { return .failure(.invalidAmount) }
        if let currency = parsed.currency {
            return .success(Resolved(amount: parsed.amount, currency: currency, source: .text))
        }
        // A symbol or word was there, but it isn't one currency: never the fallback.
        guard !parsed.hasCurrencyMarker else { return .failure(.ambiguousCurrency) }
        guard let fallbackCurrency, let code = isoCode(fallbackCurrency) else { return .failure(.invalidCurrency) }
        return .success(Resolved(amount: parsed.amount, currency: code, source: .fallbackCurrency))
    }

    /// A three-letter code, uppercased; nil for anything else.
    static func isoCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 3, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return code
    }
}

/// Reads a formatted amount (`"AED 1,234.50"`, `"12,50 €"`, `"-US$6.25"`,
/// `"١٫٢٣٤ د.ك."`) into a `Decimal` and, when the text names one
/// unambiguously, an ISO code. Never goes through a binary float.
public enum WalletAmountText {
    public struct Parsed: Sendable, Equatable {
        public let amount: Decimal
        /// The ISO code the text names; nil when it names none, or several.
        public let currency: String?
        /// The text has something besides the number and its sign (a symbol,
        /// a code, a word), whether or not it resolved to one currency.
        public let hasCurrencyMarker: Bool
    }

    public static func parse(_ raw: String, locale: Locale) -> Parsed? {
        let text = normalised(raw)
        guard let first = text.firstIndex(where: \.isASCIIDigit),
              let last = text.lastIndex(where: \.isASCIIDigit) else { return nil }
        let number = text[first...last]
        let outside = String(text[..<first]) + " " + String(text[text.index(after: last)...])
        guard let magnitude = decimal(number, locale: locale) else { return nil }
        let negative = outside.contains("-")
        let label = outside.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "+", with: " ")
        return Parsed(amount: negative ? -magnitude : magnitude, currency: currency(label, locale: locale),
                      hasCurrencyMarker: !symbolKey(label).isEmpty)
    }

    /// Arabic-Indic digits and separators to ASCII; every kind of space to a
    /// space; dashes and the minus sign to `-`; bidi marks dropped.
    static func normalised(_ raw: String) -> String {
        var out = ""
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669: out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            case 0x066B: out.append(".")                       // Arabic decimal separator
            case 0x066C: out.append(",")                       // Arabic thousands separator
            case 0x2212, 0x2013, 0x2010, 0x2011, 0xFE63, 0xFF0D: out.append("-")
            case _ where isBidiMark(scalar): continue
            default:
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { out.append(" ") }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    static func isBidiMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200E, 0x200F, 0x061C, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    /// A currency label as a lookup key: bidi marks and whitespace dropped,
    /// dots trimmed from the ends. The symbol table's keys and the text's
    /// label both go through it, so the locale's `"د.ك.\u{200F}"` matches the
    /// text's `" د.ك."` (KWD on an Arabic-locale phone).
    static func symbolKey(_ label: String) -> String {
        var key = ""
        for scalar in label.unicodeScalars where !isBidiMark(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            key.unicodeScalars.append(scalar)
        }
        return key.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// `1,234.50` / `1.234,50` / `1 234,50` / `1'234.50` → `Decimal`. With both
    /// `.` and `,`, the last one is the decimal separator. With one of them
    /// once, it is a decimal separator unless exactly three digits follow; then
    /// the locale decides (`1,234` is 1234 in English, 1.234 in German). The
    /// locale's separator is normalised like the text, so an Arabic locale's
    /// `٫` (U+066B) is the `.` it became: `١٫٢٣٤` is 1.234 in ar_SA.
    static func decimal(_ number: Substring, locale: Locale) -> Decimal? {
        let allowed: Set<Character> = [".", ",", " ", "'", "’"]
        guard number.allSatisfy({ $0.isASCIIDigit || allowed.contains($0) }) else { return nil }
        let marks = number.filter { $0 == "." || $0 == "," }
        var decimalMark: Character?
        if Set(marks).count == 2 {
            decimalMark = marks.last
        } else if let mark = marks.first {
            if marks.count == 1 {
                let after = number[number.index(after: number.lastIndex(of: mark)!)...].filter(\.isASCIIDigit)
                let localeMark = normalised(locale.decimalSeparator ?? ".")
                decimalMark = after.count != 3 || localeMark == String(mark) ? mark : nil
            }
        }
        var posix = ""
        for ch in number {
            if ch.isASCIIDigit { posix.append(ch) }
            else if ch == decimalMark { posix.append(".") }
            // Anything else is a grouping mark or space, and is dropped.
        }
        return LedgerDecimal.parse(posix)
    }

    /// The currency the label names, or nil when it names none or several.
    static func currency(_ label: String, locale: Locale) -> String? {
        let cleaned = label.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        guard !cleaned.isEmpty else { return nil }
        if let code = WalletAmount.isoCode(cleaned), Locale.commonISOCurrencyCodes.contains(code) { return code }
        // A code among other words ("AED", "USD") is still a code.
        let words = cleaned.split(separator: " ").map(String.init)
        let codes = Set(words.compactMap { WalletAmount.isoCode($0) }.filter(Locale.commonISOCurrencyCodes.contains))
        if codes.count == 1 { return codes.first }
        let matches = symbolTable(locale)[symbolKey(cleaned)] ?? []
        if matches.count == 1 { return matches.first }
        // `$` in a dollar locale is that locale's dollar; elsewhere it's ambiguous.
        if let own = locale.currency?.identifier, matches.contains(own) { return own }
        return nil
    }

    /// Symbol → codes, as this locale formats each currency, plus the
    /// symbols every locale writes the same way.
    static func symbolTable(_ locale: Locale) -> [String: Set<String>] {
        if let cached = cache.withLock({ $0[locale.identifier] }) { return cached }
        var table: [String: Set<String>] = [:]
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        for code in Locale.commonISOCurrencyCodes {
            formatter.currencyCode = code
            if let symbol = formatter.currencySymbol.map(symbolKey), !symbol.isEmpty, symbol.uppercased() != code {
                table[symbol, default: []].insert(code)
            }
        }
        for (symbol, code) in universal { table[symbolKey(symbol), default: []].insert(code) }
        cache.withLock { $0[locale.identifier] = table }
        return table
    }

    static let universal: [String: String] = [
        "€": "EUR", "£": "GBP", "₹": "INR", "₪": "ILS", "₩": "KRW", "฿": "THB", "₺": "TRY",
        "₽": "RUB", "₱": "PHP", "₫": "VND", "US$": "USD", "د.إ": "AED", "ر.س": "SAR", "ر.ق": "QAR",
    ]

    private static let cache = Mutex<[String: [String: Set<String>]]>([:])
}

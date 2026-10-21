import Foundation

/// The units a weight can be typed in. A tola is 11.6638 g (the Gulf's ten-tola bar is 116.638 g).
public enum WeightUnit: String, CaseIterable, Identifiable, Hashable, Sendable {
    case grams, kilograms, tola

    public var id: String { rawValue }

    /// The picker's segment: `"g"`, `"kg"`, `"tola"`.
    public var label: String {
        switch self {
        case .grams: "g"
        case .kilograms: "kg"
        case .tola: "tola"
        }
    }

    /// Exact in base 10.
    public var gramsPerUnit: Decimal {
        switch self {
        case .grams: 1
        case .kilograms: 1000
        case .tola: Decimal(string: "11.6638", locale: Locale(identifier: "en_US_POSIX"))!
        }
    }
}

/// Gold's karat; each is valued at its own Dubai retail rate.
public enum GoldKarat: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case k24 = 24, k22 = 22, k21 = 21, k18 = 18

    public var id: Int { rawValue }
    /// `"24K"`.
    public var label: String { "\(rawValue)K" }
}

/// A 24K bar's fineness, in parts per 10,000. The Dubai 24K rate is for 999.9; the server
/// values a lower fineness pro rata (`private.gold_fineness_factor`), never the phone.
public enum GoldFineness: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case f9999 = 9999, f9995 = 9995, f9990 = 9990, f9950 = 9950

    public var id: Int { rawValue }
    /// `"999.9"`, `"999.5"`, `"999"`, `"995"`.
    public var label: String {
        switch self {
        case .f9999: "999.9"
        case .f9995: "999.5"
        case .f9990: "999"
        case .f9950: "995"
        }
    }
}

/// Silver's fine share (`holdings.purity`), as a decimal (`0.999`).
public struct SilverPurity: Hashable, Sendable, Identifiable {
    public let value: Decimal
    public var id: String { MoneyFormat.plain(value) }

    public init(_ value: Decimal) { self.value = value }

    public static let fine = SilverPurity(Decimal(string: "0.999", locale: Locale(identifier: "en_US_POSIX"))!)
    public static let britannia = SilverPurity(Decimal(string: "0.958", locale: Locale(identifier: "en_US_POSIX"))!)
    public static let sterling = SilverPurity(Decimal(string: "0.925", locale: Locale(identifier: "en_US_POSIX"))!)
    public static let coin = SilverPurity(Decimal(string: "0.9", locale: Locale(identifier: "en_US_POSIX"))!)
    public static let standard: [SilverPurity] = [.fine, .britannia, .sterling, .coin]

    /// Parts per thousand: `"999"`, `"925"`, `"999.9"`.
    public var millesimal: String {
        var s = MoneyFormat.grouped(value * 1000, fractionDigits: 1)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    /// `"999 fine"`, `"925 sterling"`.
    public var label: String {
        switch self {
        case .fine: "999 fine"
        case .britannia: "958 Britannia"
        case .sterling: "925 sterling"
        case .coin: "900 coin"
        default: millesimal
        }
    }

    /// The standard purities, plus `current` when a holding has another one (set on the web).
    public static func choices(including current: SilverPurity) -> [SilverPurity] {
        standard.contains(current) ? standard : standard + [current]
    }
}


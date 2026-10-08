import SwiftUI

/// Type scale: New York (the system serif) for hero numbers, SF Pro for UI,
/// monospaced digits wherever money lines up in a column.
public enum Typography {
    /// The hero's base size at the default text size; views scale it with
    /// `@ScaledMetric(relativeTo: .largeTitle)` so it grows with Dynamic Type
    /// like the unit beside it.
    public static let heroBaseSize: CGFloat = 52
    /// The month's spend on Overview, at a Dynamic-Type-scaled size.
    public static func hero(size: CGFloat) -> Font {
        Font.system(size: size, weight: .regular, design: .serif).monospacedDigit()
    }
    public static let heroUnit = Font.system(.title3, design: .serif)
    /// Screen and section display titles.
    public static let display = Font.system(.largeTitle, design: .serif)
    public static let sectionTitle = Font.system(.title3, design: .serif).weight(.semibold)
    public static let cardTitle = Font.system(.headline)
    public static let body = Font.system(.body)
    public static let rowTitle = Font.system(.body).weight(.medium)
    public static let rowMeta = Font.system(.subheadline)
    public static let caption = Font.system(.caption)
    public static let chip = Font.system(.caption2).weight(.semibold)
    /// Money in rows: tabular so amounts align.
    public static let amount = Font.system(.body).monospacedDigit().weight(.medium)
    public static let amountLarge = Font.system(.title2, design: .serif).monospacedDigit()
}

extension DynamicTypeSize {
    /// Rows put amounts and chips under the title (instead of beside it) from
    /// xxxLarge up: the audit saw "ADCB •4…" truncate there already.
    public var prefersStackedRows: Bool { self >= .xxxLarge }
}

extension Tone {
    public var color: Color {
        switch self {
        case .neutral: Palette.muted
        case .positive: Palette.positive
        case .warn: Palette.warn
        case .danger: Palette.danger
        case .info: Palette.info
        }
    }

    public var softColor: Color {
        switch self {
        case .neutral: Palette.surface2
        case .positive: Palette.positiveSoft
        case .warn: Palette.warnSoft
        case .danger: Palette.dangerSoft
        case .info: Palette.infoSoft
        }
    }
}

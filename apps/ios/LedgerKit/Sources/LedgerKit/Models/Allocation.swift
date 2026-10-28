import Foundation

/// One row of `net_worth.allocation`: an asset class's value and its share of all assets, or
/// (`owed`) what the cards owe, as a negative value with no share. Server order: assets largest
/// first, then owed. Every figure is the server's.
public struct AllocationSlice: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { assetClass }
    /// `cash`, `gold`, `silver`, `plan`, `broker`, `security`, `deposit`, `structured_note`,
    /// `savings_account` or `owed`.
    public let assetClass: String
    public let valueAed: Decimal
    /// Percent of all assets (`"49.15"`); nil for owed.
    public let sharePct: Decimal?

    public init(assetClass: String, valueAed: Decimal, sharePct: Decimal? = nil) {
        self.assetClass = assetClass
        self.valueAed = valueAed
        self.sharePct = sharePct
    }

    enum CodingKeys: String, CodingKey { case assetClass = "class", valueAed, sharePct }

    public var isOwed: Bool { assetClass == "owed" }

    /// `"Cash"`, `"Gold"`, `"Shares and funds"`, `"Owed on cards"`.
    public var label: String {
        switch assetClass {
        case "cash": "Cash"
        case "gold": "Gold"
        case "silver": "Silver"
        case "plan": "Plans"
        case "broker": "Broker accounts"
        case "security": "Shares and funds"
        case "deposit": "Fixed deposits"
        case "structured_note": "Structured notes"
        case "savings_account": "Savings accounts"
        case "owed": "Owed on cards"
        default: assetClass.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The chart colour's token, fixed per class so a class looks the same wherever it is drawn.
    public var colorToken: String {
        switch assetClass {
        case "cash": "cat-4"
        case "gold": "cat-3"
        case "silver": "cat-11"
        case "plan": "cat-7"
        case "broker": "cat-15"
        case "security": "cat-5"
        case "deposit": "cat-13"
        case "structured_note": "cat-9"
        case "savings_account": "cat-6"
        default: "cat-10"
        }
    }

    /// `"AED 593,370.64"`; owed reads `"−AED 8,966.35"`.
    public var valueText: String {
        valueAed < 0 ? "−" + MoneyFormat.aed(-valueAed) : MoneyFormat.aed(valueAed)
    }

    /// `"49.2%"`; nil for owed.
    public var shareText: String? {
        sharePct.map { MoneyFormat.grouped($0, fractionDigits: 1) + "%" }
    }

    /// VoiceOver: `"Gold, AED 593,370.64, 49.2% of assets"`.
    public var accessibilityLabel: String {
        "\(label), \(valueText)" + (shareText.map { ", \($0) of assets" } ?? "")
    }
}

/// The allocation card's parts.
public enum Allocation {
    /// The asset classes in the server's order (largest first); owed is not an asset.
    public static func assets(_ slices: [AllocationSlice]) -> [AllocationSlice] {
        slices.filter { !$0.isOwed && $0.valueAed > 0 }
    }

    /// What the cards owe, shown as its own negative line under the assets.
    public static func owed(_ slices: [AllocationSlice]) -> AllocationSlice? { slices.first(where: \.isOwed) }

    /// A chart needs two classes to compare; one is the whole.
    public static func showsChart(_ slices: [AllocationSlice]) -> Bool { assets(slices).count >= 2 }

    public static let note = "Each class's share of everything you own. What the cards owe isn't an asset, so it sits apart."
}

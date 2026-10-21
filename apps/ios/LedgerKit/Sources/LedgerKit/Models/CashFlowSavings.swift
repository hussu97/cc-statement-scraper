import Foundation

/// One row of `rpc('cash_flow_savings')`: a month's saving into one holding (linked payments), or
/// (`holdingCode` nil) saving filed by category with no holding. Every figure is the server's.
public struct SavingByHolding: Decodable, Sendable, Hashable {
    public let month: CalendarDay
    public let holdingCode: String?
    public let holdingName: String?
    public let holdingKind: HoldingKind?
    public let amountAed: Decimal
    public let txnCount: Int

    public init(month: CalendarDay, holdingCode: String? = nil, holdingName: String? = nil,
                holdingKind: HoldingKind? = nil, amountAed: Decimal, txnCount: Int = 1) {
        self.month = month
        self.holdingCode = holdingCode
        self.holdingName = holdingName
        self.holdingKind = holdingKind
        self.amountAed = amountAed
        self.txnCount = txnCount
    }
}

/// One line under Cash flow's Saving: `"RL360 plan · AED 12,575.50 · 2 transactions"`.
public struct SavingLine: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode ?? "unassigned" }
    public let holdingCode: String?
    public let label: String
    public let kind: HoldingKind?
    public let amountAed: Decimal
    public let txnCount: Int

    /// `"−AED 500.00"` for a month where more came out than went in.
    public var amountText: String { amountAed < 0 ? "−" + MoneyFormat.aed(-amountAed) : MoneyFormat.aed(amountAed) }
    public var countText: String { txnCount == 1 ? "1 transaction" : "\(txnCount) transactions" }
    /// The SF Symbol beside it: the holding's kind, or a tray for the unassigned.
    public var systemImage: String { kind?.systemImage ?? "tray" }
}

public enum CashFlowSavings {
    /// The month's lines: each holding in the server's order (largest first), Unassigned last.
    /// A line with nothing in it is left out.
    public static func lines(_ rows: [SavingByHolding], month: CalendarDay) -> [SavingLine] {
        let inMonth = rows.filter { $0.month == month.startOfMonth && ($0.amountAed != 0 || $0.txnCount > 0) }
        let assigned = inMonth.filter { $0.holdingCode != nil }
        let unassigned = inMonth.filter { $0.holdingCode == nil }
        return (assigned + unassigned).map {
            SavingLine(holdingCode: $0.holdingCode, label: $0.holdingCode == nil ? unassignedLabel : ($0.holdingName ?? "A holding"),
                       kind: $0.holdingKind, amountAed: $0.amountAed, txnCount: $0.txnCount)
        }
    }

    /// Shown only when there is something to split: one Unassigned line is the Saving line again.
    public static func showsBreakdown(_ lines: [SavingLine]) -> Bool {
        lines.contains { $0.holdingCode != nil }
    }

    public static let unassignedLabel = "Unassigned"
    public static let note =
        "Saving by investment: payments linked to a holding. Unassigned is saving filed by category only; link its payments from their transactions."
}

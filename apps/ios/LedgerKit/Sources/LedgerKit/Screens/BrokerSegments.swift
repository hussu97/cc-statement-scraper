import Foundation

/// Zerodha's two halves, Kite (stocks, ETFs) and Coin (mutual funds), as the account screen words
/// them: one line each under the three numbers, and one card each on the Portfolio tab. Every
/// figure is the server's (`broker_portfolio.segments`, each position's cost); nothing is summed
/// here (CLAUDE.md §2.2).
public enum BrokerSegmentText {
    /// `"Kite"`, `"Coin"`; another segment is `"Other"`.
    public static func label(_ segment: String?) -> String {
        switch segment {
        case "kite": "Kite"
        case "coin": "Coin"
        default: "Other"
        }
    }

    /// What a segment holds: `"Stocks and ETFs"`, `"Mutual funds"`.
    public static func holds(_ segment: String?) -> String {
        switch segment {
        case "kite": "Stocks and ETFs"
        case "coin": "Mutual funds"
        default: "Other holdings"
        }
    }
}

/// Kite or Coin in one line: invested, current, and the P&L with its return.
public struct BrokerSegmentLine: Sendable, Hashable, Identifiable {
    public var id: String { segment }
    public let segment: String
    public let title: String
    public let subtitle: String
    public let investedText: String
    public let valueText: String
    /// `"+INR 27,447 (+17.2%)"`.
    public let profitText: String
    public let profitTone: Tone

    init(_ s: BrokerPortfolio.Segment, currency: String) {
        segment = s.segment
        title = BrokerSegmentText.label(s.segment)
        subtitle = BrokerSegmentText.holds(s.segment)
        investedText = NoteText.whole(s.invested, currency: currency)
        valueText = NoteText.whole(s.value, currency: currency)
        profitText = NoteText.signedWhole(s.profit, currency: currency)
            + (s.returnPct.map { " (\(NoteText.signedPct($0, digits: 1)))" } ?? "")
        profitTone = NoteText.profitTone(s.profit)
    }

    /// For VoiceOver.
    public var accessibilityLabel: String {
        "\(title), \(subtitle): invested \(investedText), worth \(valueText), \(profitText)"
    }
}

/// A segment's card on the Portfolio tab: its holdings, each with units and cost.
public struct BrokerSegmentGroup: Sendable, Hashable, Identifiable {
    public var id: String { segment }
    public let segment: String
    /// `"KITE"` over `"Stocks and ETFs"`.
    public let eyebrow: String
    public let title: String
    public let rows: [BrokerHoldingRow]

    /// Kite first, then Coin, then anything else; positions in the order given; empty groups left out.
    static func groups(_ positions: [BrokerPortfolio.Position]) -> [BrokerSegmentGroup] {
        let known = ["kite", "coin"]
        let key = { (p: BrokerPortfolio.Position) in p.segment.flatMap { known.contains($0) ? $0 : nil } ?? "other" }
        return (known + ["other"]).compactMap { segment in
            let items = positions.filter { key($0) == segment }
            guard !items.isEmpty else { return nil }
            return BrokerSegmentGroup(segment: segment, eyebrow: BrokerSegmentText.label(segment).uppercased(),
                                      title: BrokerSegmentText.holds(segment),
                                      rows: items.map { BrokerHoldingRow($0, showsCost: true) })
        }
    }
}

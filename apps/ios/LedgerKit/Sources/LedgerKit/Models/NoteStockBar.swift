import Foundation

/// One stock of a live note on a bar: `GOOGL  316.80  ▕────●──┃──▏  needs +9.3%`. The bar runs
/// from the lowest relevant level (the barrier, today's close, the start) to the highest (the
/// call level, the close, the start), padded a little; it carries a tick at the call level, a tick
/// at the coupon barrier (or, without one, the break-even) and a dot at today's close. Every level
/// and distance is the server's (`underlyings[]`); the positions are drawing arithmetic only.
public struct NoteStockBar: Sendable, Hashable, Identifiable {
    public var id: String { symbol }
    public let symbol: String
    public let isWorst: Bool
    /// `"316.80"`, or `"—"` before the first close.
    public let closeText: String
    /// `"start 346.36"`.
    public let startText: String
    /// `"needs +9.3%"`, `"at call level"`, `"above break-even"`, `"No price yet"`.
    public let statusText: String
    public let statusTone: Tone
    /// Where along the bar (0 = left, 1 = right) each mark sits; nil when the note has no such level.
    public let callAt: Double?
    public let barrierAt: Double?
    /// The barrier tick's name: `"barrier"` (coupon) or `"break-even"`.
    public let barrierLabel: String?
    public let closeAt: Double?
    /// The dot: at or above the call level positive, between barrier and call warn, below the barrier danger.
    public let dotTone: Tone

    /// Under the bars: what the marks are.
    public static let legend = "Tall tick: call level · short tick: coupon barrier or break-even · dot: last close"

    /// Each side's padding, as a share of the span.
    static let padding: Decimal = Decimal(string: "0.08")!

    /// A live note's stocks, the one holding it back first, then by how far each is from its start.
    public static func bars(_ underlyings: [NoteDetail.Underlying]) -> [NoteStockBar] {
        underlyings
            .sorted { a, b in
                if a.isWorst != b.isWorst { return a.isWorst }
                return (a.perfPct ?? .greatestFiniteMagnitude) < (b.perfPct ?? .greatestFiniteMagnitude)
            }
            .map(NoteStockBar.init)
    }

    init(_ u: NoteDetail.Underlying) {
        symbol = u.symbol
        isWorst = u.isWorst
        closeText = u.close.map { MoneyFormat.grouped($0, fractionDigits: 2) } ?? "—"
        startText = "start \(MoneyFormat.grouped(u.initial, fractionDigits: 2))"
        let barrier = u.couponLevel ?? u.breakEvenLevel
        barrierLabel = u.couponLevel != nil ? "barrier" : u.breakEvenLevel != nil ? "break-even" : nil

        // The words: the distance to the call, else (no autocall left) to break-even.
        if u.close == nil {
            statusText = "No price yet"
            statusTone = .neutral
        } else if let d = u.toAutocallPct {
            statusText = d <= 0 ? "at call level" : "needs +\(NoteVerdict.gap(d))"
            statusTone = d <= 0 ? .positive : .warn
        } else if let d = u.toBreakEvenPct {
            statusText = d <= 0 ? "above break-even" : "needs +\(NoteVerdict.gap(d))"
            statusTone = d <= 0 ? .positive : .danger
        } else {
            statusText = ""
            statusTone = .neutral
        }

        // The geometry.
        let lows = [barrier, u.close, u.initial].compactMap { $0 }
        let highs = [u.autocallLevel, u.close, u.initial].compactMap { $0 }
        let lo = lows.min() ?? u.initial
        let hi = highs.max() ?? u.initial
        let span = hi - lo
        let pad = span > 0 ? span * Self.padding : max(hi * Self.padding, 1)
        let from = lo - pad
        let width = (hi + pad) - from
        func at(_ v: Decimal?) -> Double? {
            guard let v, width > 0 else { return nil }
            return min(max(((v - from) / width).chartValue, 0), 1)
        }
        callAt = at(u.autocallLevel)
        barrierAt = at(barrier)
        closeAt = at(u.close)

        if let close = u.close {
            if let call = u.autocallLevel, close >= call {
                dotTone = .positive
            } else if let barrier, close < barrier {
                dotTone = .danger
            } else if u.autocallLevel != nil {
                dotTone = .warn
            } else {
                dotTone = barrier == nil ? .neutral : .positive
            }
        } else {
            dotTone = .neutral
        }
    }

    /// `"GOOGL, 316.80, start 346.36, needs +9.3%"` for VoiceOver.
    public var accessibilityLabel: String {
        [symbol, closeText, startText, statusText].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

import Foundation

/// A structured note's state (`structured_notes.status`, or the evaluator's for a live one).
/// A status this build doesn't know reads as live, as on the web.
public enum NoteStatus: String, Sendable, Hashable {
    case live
    case awaitingStrike = "awaiting_strike"
    case autocalled, matured, cancelled

    public init(raw: String?) { self = raw.flatMap(NoteStatus.init(rawValue:)) ?? .live }

    /// The badge: `"Live"`, `"Called early"`.
    public var label: String {
        switch self {
        case .live: "Live"
        case .awaitingStrike: "Not struck yet"
        case .autocalled: "Called early"
        case .matured: "Matured"
        case .cancelled: "Cancelled"
        }
    }

    public var tone: Tone {
        switch self {
        case .live: .info
        case .awaitingStrike, .matured: .neutral
        case .autocalled: .positive
        case .cancelled: .warn
        }
    }

    /// Called, matured or cancelled: the note pays nothing more.
    public var isEnded: Bool { self == .autocalled || self == .matured || self == .cancelled }
}

/// Coupons, redemption and their total, in the note's currency.
public struct NoteMoney: Decodable, Sendable, Hashable {
    public let coupons: Decimal
    public let redemption: Decimal
    public let total: Decimal
}

/// The next observation (or the final valuation) and what it would pay at today's prices.
public struct NoteNext: Decodable, Sendable, Hashable {
    public struct Coupon: Decodable, Sendable, Hashable {
        public let ratePct: Decimal
        public let barrierPct: Decimal
        public let amount: Decimal
        public let wouldPay: Bool
    }

    public struct Autocall: Decodable, Sendable, Hashable {
        public let triggerPct: Decimal
        public let redemptionPct: Decimal
        public let amount: Decimal
        public let wouldCall: Bool
    }

    /// `observation` or `final`.
    public let kind: String
    public let seq: Int?
    public let obsDate: CalendarDay
    public let payDate: CalendarDay
    /// Days from today (Dubai) to `obsDate`.
    public let days: Int
    public let isFinal: Bool
    public let coupon: Coupon?
    public let autocall: Autocall?
}

/// One note in `structured_notes_summary` (and the head of `structured_note_detail`). Every figure
/// is the server's (`private.note_evaluate`); numbers arrive as decimal strings.
public struct NoteSummary: Decodable, Sendable, Hashable, Identifiable {
    public struct Result: Decodable, Sendable, Hashable {
        public let total: Decimal
        public let profit: Decimal
        public let returnPct: Decimal
    }

    public struct Worst: Decodable, Sendable, Hashable {
        /// The worst share's last close in % of its initial level.
        public let pct: Decimal
        public let symbol: String
        public let priced: Bool
    }

    public struct IfEndedToday: Decodable, Sendable, Hashable {
        public let payoutPct: Decimal
        public let settlement: String
        public let amount: Decimal
        public let total: Decimal
        public let profit: Decimal
    }

    public var id: String { noteCode }
    public let noteCode: String
    public let holdingCode: String
    public let name: String
    public let institution: String?
    public let productName: String
    public let isin: String?
    public let issuer: String?
    public let currency: String
    /// Raw; `noteStatus` reads it.
    public let status: String
    /// An observation has passed without the closes it needs.
    public let awaitingPrices: Bool
    public let tradeDate: CalendarDay
    public let maturityDate: CalendarDay
    public let endedOn: CalendarDay?
    public let invested: Decimal
    public let nominal: Decimal
    public let purchasePricePct: Decimal
    public let fundingAccountCode: String?
    public let received: NoteMoney
    public let due: NoteMoney
    /// Set once the note has ended.
    public let result: Result?
    public let worstNow: Worst?
    public let breakEvenPct: Decimal?
    public let next: NoteNext?
    public let ifEndedToday: IfEndedToday?
    /// Its shares' price symbols in term-sheet order (null from the server when it has none).
    public let symbols: [String]?

    public var noteStatus: NoteStatus { NoteStatus(raw: status) }
    public var isEnded: Bool { noteStatus.isEnded }
}

extension NoteSummary {
    /// `"USD 37,250.00"`.
    public func money(_ value: Decimal) -> String { MoneyFormat.amount(value, currency: currency) }

    /// `"+USD 100.00"`, `"−USD 5,975.22"`.
    public func signed(_ value: Decimal) -> String { NoteText.signed(value, currency: currency) }

    /// The row's detail line: `"AMZN · MSFT · worst AMZN at 87.05% · next 26 Nov"`, or for an
    /// ended note `"GOOGL · ended 14 Jun 2026"`.
    public func rowDetail(today: CalendarDay = LedgerDates.today()) -> String {
        var parts = [(symbols ?? []).joined(separator: " · ")].filter { !$0.isEmpty }
        if isEnded {
            if let endedOn { parts.append("ended \(LedgerDates.fullDayLabel(endedOn))") }
        } else {
            if let w = worstNow { parts.append("worst \(w.symbol) at \(NoteText.pct(w.pct, digits: 2))") }
            if let next { parts.append("next \(LedgerDates.dayLabel(next.obsDate, today: today))") }
        }
        return parts.joined(separator: " · ")
    }

    /// The next date's outlook, as the web's row words it: `"would call"` (only when it would),
    /// else the coupon `"on track"` / `"at risk"`. Nil for an ended note or without either.
    public var nextOutlook: (text: String, tone: Tone)? {
        guard !isEnded, let next else { return nil }
        if let call = next.autocall { return call.wouldCall ? ("Would call", .positive) : nil }
        if let coupon = next.coupon {
            return coupon.wouldPay ? ("Coupon on track", .positive) : ("Coupon at risk", .warn)
        }
        return nil
    }

    /// Under the invested amount: the result of an ended note, else what it has paid so far.
    public var rowResult: (text: String, tone: Tone) {
        if isEnded, let result {
            return ("\(signed(result.profit)) (\(NoteText.pct(result.returnPct)))", result.profit < 0 ? .danger : .positive)
        }
        if received.total > 0 { return ("\(money(received.total)) received", .neutral) }
        return ("invested", .neutral)
    }

    /// `"Example Bank M Phoenix …, Live, invested USD 37,250.00, …"` for VoiceOver.
    public var accessibilityLabel: String {
        var parts = [name, noteStatus.label]
        if awaitingPrices { parts.append("awaiting prices") }
        parts.append("invested \(money(invested))")
        parts.append(rowDetail())
        if let outlook = nextOutlook { parts.append(outlook.text.lowercased()) }
        parts.append(rowResult.text)
        return parts.joined(separator: ", ")
    }
}

/// Live notes first, then ended ones, in the server's order (live first, newest trade first).
public struct NoteGroups: Sendable, Hashable {
    public let live: [NoteSummary]
    public let ended: [NoteSummary]

    public init(_ notes: [NoteSummary], fundingAccount: String? = nil) {
        let mine = notes.filter { fundingAccount == nil || $0.fundingAccountCode == fundingAccount }
        live = mine.filter { !$0.isEnded }
        ended = mine.filter(\.isEnded)
    }

    public var isEmpty: Bool { live.isEmpty && ended.isEmpty }

    /// The card's empty state, said only once loaded.
    public static func emptyMessage(canEdit: Bool) -> String {
        canEdit
            ? "Upload a note's term sheet: Bank Ledger reads its coupons, autocalls and payout, follows the shares every day and shows how close each barrier is."
            : "The ledger's owner can add structured notes here."
    }
}

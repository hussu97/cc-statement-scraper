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

    /// What it fetches sold today at the broker's bid (`value`); `profit` is that plus the coupons
    /// received, against what was invested. Nil without a broker mark.
    public struct Market: Decodable, Sendable, Hashable {
        /// The bid in % of the nominal, when the broker prices it that way.
        public let pricePct: Decimal?
        public let value: Decimal
        public let asOf: CalendarDay?
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
    /// Sold today at the broker's bid (20261027165732); nil without a mark, or from an older server.
    public let market: Market?
    /// What it pays if called at its next autocall date (the first autocall scenario); nil when no
    /// autocall date is left, or from an older server.
    public let ifCalledNext: NoteDetail.AutocallScenario?
    /// The note in one line (20261027200000); nil from an older server.
    public let verdict: NoteVerdict?

    public var noteStatus: NoteStatus { NoteStatus(raw: status) }
    public var isEnded: Bool { noteStatus.isEnded }
}

extension NoteSummary {
    /// `"USD 37,250.00"`.
    public func money(_ value: Decimal) -> String { MoneyFormat.amount(value, currency: currency) }

    /// `"+USD 100.00"`, `"−USD 5,975.22"`.
    public func signed(_ value: Decimal) -> String { NoteText.signed(value, currency: currency) }
}

/// A live note in a short list (Investments, the account that pays for it): its name, its verdict
/// and what it is worth today (or, without a broker mark, what was paid). Opens the note.
public struct NoteListRow: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let title: String
    public let verdict: String?
    public let verdictTone: Tone
    /// `"Worth today"` or `"Paid"`.
    public let valueLabel: String
    /// `"USD 23,350"`.
    public let valueText: String

    public init(_ note: NoteSummary, today: CalendarDay = LedgerDates.today()) {
        holdingCode = note.holdingCode
        title = note.name
        verdict = note.verdict?.headline(today: today)
        verdictTone = note.verdict?.tone ?? .neutral
        if let market = note.market {
            valueLabel = "Worth today"
            valueText = NoteText.whole(market.value, currency: note.currency)
        } else {
            valueLabel = "Paid"
            valueText = NoteText.whole(note.invested, currency: note.currency)
        }
    }

    /// For VoiceOver.
    public var accessibilityLabel: String {
        ([title, verdict].compactMap { $0 } + ["\(valueLabel) \(valueText)"]).joined(separator: ", ")
    }

    /// The live notes to list: those paid from `fundingAccount` (every one when nil), leaving out
    /// the holdings a synced broker account already shows (`excluding`). Never an ended note.
    public static func rows(_ notes: [NoteSummary], fundingAccount: String? = nil, excluding: Set<String> = [],
                            today: CalendarDay = LedgerDates.today()) -> [NoteListRow] {
        notes
            .filter { !$0.isEnded && !excluding.contains($0.holdingCode) }
            .filter { fundingAccount == nil || $0.fundingAccountCode == fundingAccount }
            .map { NoteListRow($0, today: today) }
    }
}

import Foundation
import Observation

/// The words a Kite or Coin position uses, shared by the holdings list and the position screen.
public enum BrokerDetailText {
    /// `"Stock"`, `"ETF"`, `"Fund"`; nil when the broker doesn't say.
    public static func assetLabel(_ assetClass: String?) -> String? {
        switch assetClass {
        case "stock": "Stock"
        case "etf": "ETF"
        case "fund": "Fund"
        default: nil
        }
    }

    /// What a position is: `"ACMEAD · NSE"`, `"ETF · NIFTYBEES · BSE"`, a fund `"Equity · Northwind Mutual Fund"`.
    public static func positionLine(_ p: BrokerPortfolio.Position) -> String {
        let d = p.detail
        let parts = d.assetClass == "fund"
            ? [d.category, d.issuer]
            : [d.assetClass == "etf" ? "ETF" : nil, p.symbol == p.isin ? nil : p.symbol, d.exchange]
        let line = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? (p.isin ?? "") : line
    }

    /// A unit price: grouped, 2–4 decimals (`"193.8273"`, `"1,372.70"`).
    public static func price(_ v: Decimal, currency: String) -> String {
        let rounded = MoneyFormat.rounded(v, scale: 4)
        let digits = rounded == MoneyFormat.rounded(v, scale: 2) ? 2 : (rounded == MoneyFormat.rounded(v, scale: 3) ? 3 : 4)
        return "\(currency.uppercased()) \(MoneyFormat.grouped(rounded, fractionDigits: digits))"
    }

    /// `"INR 193.8273 NAV on 27 Oct"` for a fund, else `"INR 240.05"`.
    public static func priceLine(_ p: BrokerPortfolio.Position, today: CalendarDay = LedgerDates.today()) -> String {
        guard let price = p.price else { return "—" }
        let text = Self.price(price, currency: p.currency)
        guard p.detail.assetClass == "fund" else { return text }
        return p.detail.priceDate.map { "\(text) NAV on \(LedgerDates.dayLabel($0, today: today))" } ?? "\(text) NAV"
    }

    /// The positions by the chosen column: numbers largest first (unknowns last), names A–Z.
    public static func sorted(_ positions: [BrokerPortfolio.Position], by sort: BrokerHoldingSort) -> [BrokerPortfolio.Position] {
        let byName: (BrokerPortfolio.Position, BrokerPortfolio.Position) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if sort == .name { return positions.sorted(by: byName) }
        let field: (BrokerPortfolio.Position) -> Decimal? = switch sort {
        case .value: \.value
        case .returnPct: \.detail.returnPct
        case .today: \.detail.dayChangePct
        case .weight: \.detail.weightPct
        case .name: { _ in nil }
        }
        return positions.sorted { a, b in
            switch (field(a), field(b)) {
            case let (x?, y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: byName(a, b)
            }
        }
    }

    // MARK: SIPs

    /// `"INR 2,184 monthly, on the 5th"`.
    public static func sipSchedule(_ s: BrokerSip) -> String {
        let amount = s.amount.map { NoteText.whole($0, currency: s.currency) } ?? "—"
        let freq = s.frequency.map { " \($0)" } ?? ""
        let day = s.day.map { NSDecimalNumber(decimal: $0).intValue }
        let on = s.frequency == "monthly" ? day.flatMap { (1...31).contains($0) ? ", on the \(ordinal($0))" : nil } ?? "" : ""
        return amount + freq + on
    }

    /// `"Steps up 3% every 2 Oct"`; nil without a step-up.
    public static func stepUp(_ stepUp: [String: Decimal]?) -> String? {
        guard let (key, rate) = stepUp?.sorted(by: { $0.key < $1.key }).first, rate > 0 else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[0]), (1...31).contains(parts[1]) else { return nil }
        let month = CalendarDay(year: 2000, month: parts[0], day: 1)
        return "Steps up \(NoteText.pct(rate)) every \(parts[1]) \(LedgerDates.monthAbbrev(month))"
    }

    /// A SIP's state: a rejected instalment (dated in India, as Zerodha dates it) is a warning.
    public static func sipStatus(_ s: BrokerSip, today: CalendarDay = LedgerDates.today()) -> (text: String, tone: Tone) {
        if s.missed {
            let which = s.lastOrder?.at.map { "The \(LedgerDates.dayLabel(istDay($0), today: today)) instalment was" }
                ?? "The last instalment was"
            let why = s.lastOrder?.message?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return ("\(which) rejected" + (why.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""), .danger)
        }
        switch s.status {
        case "paused": return ("Paused", .neutral)
        case "cancelled": return ("Cancelled", .neutral)
        case "active": break
        default: return ("Not active", .neutral)
        }
        let done = s.completed.map { NSDecimalNumber(decimal: $0).intValue } ?? 0
        let count = done > 0 ? "\(done) instalment\(done == 1 ? "" : "s") so far" : "Active"
        let next = s.nextInstalment.map { " · next \(LedgerDates.dayLabel($0, today: today))" } ?? ""
        return (count + next, .positive)
    }

    /// An instant's calendar day in India (an Indian instalment is dated as Zerodha dates it).
    public static func istDay(_ date: Date) -> CalendarDay {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
    }

    private static func ordinal(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "\(n)th" }
        return "\(n)" + ([1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th")
    }
}

/// A Kite or Coin position's screen, worded: what it is, four figures, its worth against its cost
/// over time, the details, and its SIPs. Every figure is the server's.
public struct BrokerPositionPresentation: Sendable, Hashable {
    public let detail: BrokerPositionDetail
    public let now: Date

    public init(_ detail: BrokerPositionDetail, now: Date = .now) {
        self.detail = detail
        self.now = now
    }

    private var today: CalendarDay { LedgerDates.today(now: now) }
    private var currency: String { detail.currency }

    public var title: String { detail.position?.name ?? detail.name }
    /// `"Fund"`, `"ETF"`; nil when the broker doesn't say.
    public var kind: String? { BrokerDetailText.assetLabel(detail.position?.detail.assetClass) }
    public var subtitle: String { detail.position.map(BrokerDetailText.positionLine) ?? detail.isin }

    /// Once no longer held: when it was last reported.
    public var noLongerHeldText: String? {
        guard detail.position == nil else { return nil }
        let when = detail.lastMarkedOn.map { " on \(LedgerDates.dayLabel($0, today: today))" } ?? ""
        return "No longer held. Zerodha last reported it\(when); what it made is on the account's Sold tab."
    }

    /// Value (with its price), P&L (on what it cost), today, and its share of the account.
    public var figures: [NoteStat] {
        guard let p = detail.position else { return [] }
        let d = p.detail
        let fund = d.assetClass == "fund"
        return [
            NoteStat("Value", p.value.map { NoteText.whole($0, currency: currency) } ?? "No price",
                     sub: BrokerDetailText.priceLine(p, today: today)),
            NoteStat("P&L", p.profit.map { NoteText.signedWhole($0, currency: currency) } ?? "—",
                     sub: [d.returnPct.map { NoteText.signedPct($0, digits: 1) },
                           p.cost.map { "on \(NoteText.whole($0, currency: currency)) invested" }].compactMap { $0 }.joined(separator: " "),
                     tone: NoteText.profitTone(p.profit)),
            NoteStat("Today", d.dayChange.map { NoteText.signedWhole($0, currency: currency) } ?? "—",
                     sub: d.dayChangePct.map { NoteText.signedPct($0, digits: 2) } ?? (fund ? "After the next NAV" : nil),
                     tone: NoteText.profitTone(d.dayChange)),
            NoteStat("Share of account", d.weightPct.map { NoteText.pct($0, digits: 2) } ?? "—"),
        ]
    }

    /// The details, label and value.
    public var facts: [NoteStat] {
        guard let p = detail.position else { return [] }
        let d = p.detail
        let fund = d.assetClass == "fund"
        let rows: [NoteStat?] = [
            p.quantity.map { NoteStat("Units", HoldingsText.units($0)) },
            d.costPrice.map { NoteStat("Average cost", BrokerDetailText.price($0, currency: currency)) },
            NoteStat(fund ? "NAV" : "Last price", BrokerDetailText.priceLine(p, today: today)),
            d.prevPrice.map { NoteStat(fund ? "Previous NAV" : "Previous close", BrokerDetailText.price($0, currency: currency)) },
            p.symbol.flatMap { symbol in
                symbol == p.isin ? nil : NoteStat("Symbol", [symbol, d.exchange].compactMap { $0 }.joined(separator: " · "))
            },
            d.category.map { NoteStat("Scheme type", $0) },
            d.issuer.map { NoteStat("Fund house", $0) },
            d.folio.map { NoteStat("Folio", $0) },
            NoteStat("ISIN", detail.isin),
            detail.lastMarkedOn.map { NoteStat("Last synced", LedgerDates.fullDayLabel($0)) },
        ]
        return rows.compactMap { $0 }
    }

    /// Its worth against what it cost, each day it was marked.
    public var chart: BrokerValueChart {
        let points = detail.series.map {
            BrokerPortfolio.Point(asOf: $0.asOf, total: $0.value ?? 0, positions: $0.value, netDeposits: 0,
                                  invested: $0.cost, estimated: false)
        }
        return BrokerValueChart(points, currency: currency, basis: .cost).forOnePosition()
    }

    public var sipRows: [BrokerSipRow] { detail.sips.map { BrokerSipRow($0, today: today) } }
}

/// Loads one position for its screen (`broker_position_detail`).
@MainActor
@Observable
public final class BrokerPositionModel {
    public private(set) var state: LoadState<BrokerPositionDetail?> = .idle
    private let api: any LedgerAPI

    public init(api: any LedgerAPI) {
        self.api = api
    }

    public func load(profileCode: String, accountCode: String, isin: String) async {
        state = state.startLoading()
        do {
            state = .loaded(try await api.brokerPosition(profileCode: profileCode, accountCode: accountCode, isin: isin))
        } catch {
            state = state.fail(error)
        }
    }
}

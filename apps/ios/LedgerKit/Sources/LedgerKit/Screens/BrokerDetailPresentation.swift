import Foundation

// Zerodha Kite and Coin in detail (tasks/todo.md §14), worded: where the money sits, what stands
// out, Coin's SIPs, and every position sortable. Sorting orders the server's numbers; nothing here
// adds money up (CLAUDE.md §2.2).

/// How the holdings list is ordered.
public enum BrokerHoldingSort: String, Sendable, Hashable, CaseIterable, Identifiable {
    case value, returnPct, today, weight, name
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .value: "Value"
        case .returnPct: "P&L %"
        case .today: "Today"
        case .weight: "Weight"
        case .name: "Name"
        }
    }
}

/// One position in the holdings list: what it is, its value, and the figure it is sorted by.
public struct BrokerPositionRow: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let isin: String?
    public let title: String
    /// `"ACMEAD · NSE · 2 units"`, `"Equity · Northwind Mutual Fund · 1,825.551 units"`.
    public let subtitle: String
    public let valueText: String
    /// P&L with its return, today's move, or the weight: whichever the list is sorted by.
    public let figureText: String
    public let figureTone: Tone

    init(_ p: BrokerPortfolio.Position, sort: BrokerHoldingSort) {
        holdingCode = p.holdingCode
        isin = p.isin
        title = p.name
        let units = p.quantity.map(HoldingsText.units)
        subtitle = [BrokerDetailText.positionLine(p), units].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        valueText = p.value.map { NoteText.whole($0, currency: p.currency) } ?? "No price"
        let d = p.detail
        switch sort {
        case .today:
            if let change = d.dayChange {
                figureText = "\(NoteText.signedWhole(change, currency: p.currency))"
                    + (d.dayChangePct.map { " (\(NoteText.signedPct($0, digits: 2)))" } ?? "") + " today"
                figureTone = NoteText.profitTone(change)
            } else {
                figureText = "No move yet today"
                figureTone = .neutral
            }
        case .weight:
            figureText = d.weightPct.map { "\(NoteText.pct($0, digits: 2)) of the account" } ?? "—"
            figureTone = .neutral
        case .value, .returnPct, .name:
            let profit = p.profit.map { NoteText.signedWhole($0, currency: p.currency) }
            let ret = d.returnPct.map { "(\(NoteText.signedPct($0, digits: 1)))" }
            figureText = [profit, ret].compactMap { $0 }.joined(separator: " ")
            figureTone = NoteText.profitTone(p.profit)
        }
    }

    /// For VoiceOver.
    public var accessibilityLabel: String { [title, subtitle, valueText, figureText].joined(separator: ", ") }
}

/// A line of the allocation: a type (or fund house), its share and value, and its return.
public struct BrokerAllocationRow: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    /// `"Stocks · 47"`.
    public let title: String
    /// 0…1, for the bar.
    public let share: Double
    public let weightText: String
    public let valueText: String
    public let returnText: String?
    public let returnTone: Tone
    /// Which palette colour (0-based, in the server's order).
    public let colorIndex: Int
}

/// A highlight list: "Best since bought", "Up most today", …
public struct BrokerHighlightSection: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public let title: String
    public let rows: [Row]

    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String { isin ?? title }
        public let isin: String?
        public let title: String
        public let figureText: String
        public let tone: Tone
    }
}

/// A Coin SIP in a few lines: fund, schedule and step-up, its state, and a badge.
public struct BrokerSipRow: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// `"INR 2,184 monthly, on the 5th · Steps up 3% every 2 Oct"`.
    public let schedule: String
    /// `"68 instalments so far · next 5 Nov"`, or why the last one failed.
    public let statusText: String
    public let statusTone: Tone
    /// `"Missed"`, `"Paused"`; nil for an active SIP in order.
    public let badge: String?

    public init(_ s: BrokerSip, today: CalendarDay = LedgerDates.today()) {
        id = s.sipCode
        title = s.fund
        schedule = [BrokerDetailText.sipSchedule(s), BrokerDetailText.stepUp(s.stepUp)].compactMap { $0 }.joined(separator: " · ")
        let status = BrokerDetailText.sipStatus(s, today: today)
        statusText = status.text
        statusTone = status.tone
        badge = s.missed ? "Missed" : s.status == "paused" ? "Paused" : nil
    }
}

extension BrokerPortfolioPresentation {
    /// Zerodha's detail cards (allocation, highlights, SIPs) and the sortable holdings list show
    /// on an account measured against cost.
    public var showsDetail: Bool { portfolio.basis == .cost }

    /// Coin can show its allocation by fund house too.
    public var hasFundHouses: Bool { !portfolio.detail.issuers.isEmpty }

    /// Where the money sits, by type (or by fund house), largest first.
    public func allocation(byHouse: Bool) -> [BrokerAllocationRow] {
        let currency = portfolio.currency
        let pct: (Decimal?) -> (Double, String) = { w in
            (min(max(NSDecimalNumber(decimal: w ?? 0).doubleValue / 100, 0), 1), w.map { NoteText.pct($0, digits: 2) } ?? "—")
        }
        if byHouse && hasFundHouses {
            return portfolio.detail.issuers.enumerated().map { i, h in
                let (share, text) = pct(h.weightPct)
                return BrokerAllocationRow(key: h.issuer, title: h.issuer + count(h.positions), share: share, weightText: text,
                                           valueText: h.value.map { NoteText.whole($0, currency: currency) } ?? "—",
                                           returnText: nil, returnTone: .neutral, colorIndex: i)
            }
        }
        return portfolio.detail.allocation.enumerated().map { i, a in
            let (share, text) = pct(a.weightPct)
            return BrokerAllocationRow(key: a.key, title: a.label + count(a.positions), share: share, weightText: text,
                                       valueText: a.value.map { NoteText.whole($0, currency: currency) } ?? "—",
                                       returnText: a.returnPct.map { NoteText.signedPct($0, digits: 1) },
                                       returnTone: NoteText.profitTone(a.returnPct), colorIndex: i)
        }
    }

    private func count(_ n: Decimal?) -> String {
        n.map { " · \(NSDecimalNumber(decimal: $0).intValue)" } ?? ""
    }

    /// The highlight lists that have something: best and worst since bought, today's moves.
    public var highlightSections: [BrokerHighlightSection] {
        guard let h = portfolio.detail.highlights else { return [] }
        let currency = portfolio.currency
        let byReturn: (BrokerHighlights.Item) -> BrokerHighlightSection.Row = { i in
            .init(isin: i.isin, title: i.name, figureText: i.returnPct.map { NoteText.signedPct($0, digits: 1) } ?? "—",
                  tone: NoteText.profitTone(i.returnPct))
        }
        let byDay: (BrokerHighlights.Item) -> BrokerHighlightSection.Row = { i in
            .init(isin: i.isin, title: i.name,
                  figureText: [i.dayChange.map { NoteText.signedWhole($0, currency: currency) },
                               i.dayChangePct.map { NoteText.signedPct($0, digits: 2) }].compactMap { $0 }.joined(separator: " "),
                  tone: NoteText.profitTone(i.dayChange))
        }
        return [
            BrokerHighlightSection(title: "Best since bought", rows: h.best.map(byReturn)),
            BrokerHighlightSection(title: "Worst since bought", rows: h.worst.map(byReturn)),
            BrokerHighlightSection(title: "Up most today", rows: h.gainersToday.map(byDay)),
            BrokerHighlightSection(title: "Down most today", rows: h.losersToday.map(byDay)),
        ].filter { !$0.rows.isEmpty }
    }

    /// `"The five largest positions are 31.18% of the account."`; nil with five or fewer.
    public var concentrationText: String? {
        portfolio.detail.highlights?.top5WeightPct.map { "The five largest positions are \(NoteText.pct($0, digits: 2)) of the account." }
    }

    /// Coin's SIPs worth showing: all but the cancelled ones (unless their last instalment failed).
    public var sipRows: [BrokerSipRow] {
        portfolio.detail.sips.filter { $0.status != "cancelled" || $0.missed }.map { BrokerSipRow($0, today: LedgerDates.today(now: now)) }
    }

    /// `"2 instalments missed"`; nil when none.
    public var missedSipsText: String? {
        let n = portfolio.detail.sips.filter(\.missed).count
        return n == 0 ? nil : n == 1 ? "1 instalment missed" : "\(n) instalments missed"
    }

    /// The open positions as the holdings list shows them, in the chosen order (unknowns last).
    public func holdingRows(sort: BrokerHoldingSort) -> [BrokerPositionRow] {
        BrokerDetailText.sorted(portfolio.positions, by: sort).map { BrokerPositionRow($0, sort: sort) }
    }
}

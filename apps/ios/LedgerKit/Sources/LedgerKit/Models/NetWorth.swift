import Foundation

/// `rpc('net_worth')` (Wealth mode): bank cash − what the cards owe now, in AED, with how complete
/// each side is. Every figure is the server's decimal string; nothing is re-derived here.
public struct NetWorth: Decodable, Sendable, Hashable {
    public let cashAed: Decimal
    public let cashComplete: Bool
    public let cashMissingCount: Int
    public let cashStaleCount: Int
    /// The oldest balance the cash includes; nil before the first balance.
    public let cashAsOf: Date?
    public let owedAed: Decimal
    public let owedComplete: Bool
    public let owedHasEstimate: Bool
    public let netAed: Decimal
    public let complete: Bool
    public let hasBankAccounts: Bool
    /// Each active card account's outstanding, most owed first.
    public let cards: [NetWorthCard]

    public init(cashAed: Decimal, cashComplete: Bool = true, cashMissingCount: Int = 0, cashStaleCount: Int = 0,
                cashAsOf: Date? = nil, owedAed: Decimal, owedComplete: Bool = true, owedHasEstimate: Bool = false,
                netAed: Decimal, complete: Bool = true, hasBankAccounts: Bool = true, cards: [NetWorthCard] = []) {
        self.cashAed = cashAed
        self.cashComplete = cashComplete
        self.cashMissingCount = cashMissingCount
        self.cashStaleCount = cashStaleCount
        self.cashAsOf = cashAsOf
        self.owedAed = owedAed
        self.owedComplete = owedComplete
        self.owedHasEstimate = owedHasEstimate
        self.netAed = netAed
        self.complete = complete
        self.hasBankAccounts = hasBankAccounts
        self.cards = cards
    }

    enum CodingKeys: String, CodingKey {
        case cashAed, cashComplete, cashMissingCount, cashStaleCount, cashAsOf, owedAed, owedComplete
        case owedHasEstimate, netAed, complete, hasBankAccounts, cards
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cashAed = try c.decode(Decimal.self, forKey: .cashAed)
        cashComplete = try c.decodeIfPresent(Bool.self, forKey: .cashComplete) ?? true
        cashMissingCount = try c.decodeIfPresent(Int.self, forKey: .cashMissingCount) ?? 0
        cashStaleCount = try c.decodeIfPresent(Int.self, forKey: .cashStaleCount) ?? 0
        cashAsOf = try c.decodeIfPresent(Date.self, forKey: .cashAsOf)
        owedAed = try c.decode(Decimal.self, forKey: .owedAed)
        owedComplete = try c.decodeIfPresent(Bool.self, forKey: .owedComplete) ?? true
        owedHasEstimate = try c.decodeIfPresent(Bool.self, forKey: .owedHasEstimate) ?? false
        netAed = try c.decode(Decimal.self, forKey: .netAed)
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? false
        hasBankAccounts = try c.decodeIfPresent(Bool.self, forKey: .hasBankAccounts) ?? false
        cards = try c.decodeIfPresent([NetWorthCard].self, forKey: .cards) ?? []
    }

    /// The hero number without its unit: `"144,701"`, `"−2,050"` (a true minus sign).
    public var heroAmount: String {
        netAed < 0 ? "−" + MoneyFormat.hero(-netAed) : MoneyFormat.hero(netAed)
    }

    /// VoiceOver: `"Net worth, 144,701 dirhams"`.
    public var heroAccessibilityLabel: String { "Net worth, \(MoneyFormat.spokenDirhams(netAed))" }

    public var cashText: String { MoneyFormat.aed(cashAed) }
    /// `"≈ AED 14,169.62"` when an FX estimate is in it.
    public var owedText: String { (owedHasEstimate ? "≈ " : "") + MoneyFormat.aed(owedAed) }
    /// The hero's second line, taken off the cash: `"−AED 8,966.35"`, `"≈ −AED 14,169.62"`.
    public var owedDeductionText: String { (owedHasEstimate ? "≈ " : "") + "−" + MoneyFormat.aed(owedAed) }

    /// `"Cash as of 8 Oct"`: the oldest balance in the cash. Nil before the first balance.
    public func asOfText(now: Date = .now) -> String? {
        cashAsOf.map { "Cash " + CashText.asOf($0, now: now).lowercasedFirst }
    }

    /// What the figure can't vouch for, in plain words; empty when it is whole and fresh.
    public var caveats: [String] {
        var out: [String] = []
        if !hasBankAccounts {
            out.append("No bank accounts yet, so this is only what the cards owe. Add one under Accounts.")
        }
        if cashMissingCount > 0 {
            out.append(cashMissingCount == 1
                ? "1 bank account has no balance yet, so cash leaves it out."
                : "\(cashMissingCount) bank accounts have no balance yet, so cash leaves them out.")
        } else if !cashComplete {
            out.append("Some bank amounts aren't converted to AED yet, so cash may be off.")
        }
        if cashStaleCount > 0 {
            out.append(cashStaleCount == 1 ? "1 balance is over a week old." : "\(cashStaleCount) balances are over a week old.")
        }
        if !owedComplete {
            out.append("A card has no statement or balance yet, so what's owed may be short.")
        }
        if owedHasEstimate {
            out.append("What the cards owe includes a foreign-currency estimate.")
        }
        return out
    }

    /// A figure missing something warns; a whole one says so quietly.
    public var completenessTone: Tone { complete ? .positive : .warn }

    /// The line under the hero: whole, or pointing at the caveats.
    public var completenessText: String {
        complete ? "Every bank account and card is counted." : "Not complete yet: see below."
    }
}

/// One card account in `net_worth.cards`.
public struct NetWorthCard: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    public let bankCode: String
    public let nickname: String?
    public let productName: String?
    /// Nil when the card has no anchor (no statement or balance yet).
    public let outstandingAed: Decimal?
    /// `statement`, `sms`, `manual` or `none`.
    public let anchorKind: String
    public let hasEstimate: Bool

    public init(accountCode: String, bankCode: String, nickname: String? = nil, productName: String? = nil,
                outstandingAed: Decimal?, anchorKind: String = "statement", hasEstimate: Bool = false) {
        self.accountCode = accountCode
        self.bankCode = bankCode
        self.nickname = nickname
        self.productName = productName
        self.outstandingAed = outstandingAed
        self.anchorKind = anchorKind
        self.hasEstimate = hasEstimate
    }

    enum CodingKeys: String, CodingKey {
        case accountCode, bankCode, nickname, productName, outstandingAed, anchorKind, hasEstimate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountCode = try c.decode(String.self, forKey: .accountCode)
        bankCode = try c.decode(String.self, forKey: .bankCode)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        productName = try c.decodeIfPresent(String.self, forKey: .productName)
        outstandingAed = try c.decodeIfPresent(Decimal.self, forKey: .outstandingAed)
        anchorKind = try c.decodeIfPresent(String.self, forKey: .anchorKind) ?? "none"
        hasEstimate = try c.decodeIfPresent(Bool.self, forKey: .hasEstimate) ?? false
    }

    /// The nickname, else the product, else the bank.
    public var title: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let productName, !productName.isEmpty { return productName }
        return bankCode
    }

    /// `"ADCB · Platinum Rewards"` under a nickname, else `"ADCB"`.
    public var detail: String {
        if let nickname, !nickname.isEmpty, let productName, !productName.isEmpty { return "\(bankCode) · \(productName)" }
        return bankCode
    }

    /// `"AED 8,966.35"`, `"≈ AED 5,203.27"`, or `"Not known yet"` without an anchor.
    public var owedText: String {
        guard let outstandingAed else { return "Not known yet" }
        return (hasEstimate ? "≈ " : "") + MoneyFormat.aed(outstandingAed)
    }

    public var isKnown: Bool { outstandingAed != nil }
}

/// One month of `rpc('net_worth_series')`: the month's last nightly snapshot, or (the last
/// point) today's live figure.
public struct NetWorthPoint: Decodable, Sendable, Hashable, Identifiable {
    public var id: CalendarDay { month }
    public let month: CalendarDay
    public let asOf: CalendarDay
    public let cashAed: Decimal
    public let owedAed: Decimal
    public let netAed: Decimal
    public let complete: Bool
    public let isLive: Bool

    public init(month: CalendarDay, asOf: CalendarDay, cashAed: Decimal, owedAed: Decimal, netAed: Decimal,
                complete: Bool = true, isLive: Bool = false) {
        self.month = month
        self.asOf = asOf
        self.cashAed = cashAed
        self.owedAed = owedAed
        self.netAed = netAed
        self.complete = complete
        self.isLive = isLive
    }

    /// The axis label: `"Oct"`.
    public var monthLabel: String { LedgerDates.monthAbbrev(month) }
    /// The point's accessibility value: `"October 2026, AED 144,700.53, today"`.
    public var accessibilityValue: String {
        "\(LedgerDates.monthTitle(month)), \(MoneyFormat.aed(netAed))" + (isLive ? ", today" : "")
    }
}

/// Words around the net worth chart.
public enum NetWorthHistory {
    /// The chart's footnote. History is the nightly snapshots, so a new ledger has only today.
    public static func note(_ points: [NetWorthPoint]) -> String {
        let past = points.filter { !$0.isLive }.count
        if past == 0 {
            return "History starts with the first nightly snapshot: each month adds a point, so only today shows for now."
        }
        return "Each point is the month's last nightly snapshot; the last one is today. History starts with the first snapshot."
    }

    /// Whether a chart is worth drawing: two points make a line; one is the hero again.
    public static func showsChart(_ points: [NetWorthPoint]) -> Bool { points.count >= 2 }
}

extension String {
    /// `"As of 8 Oct"` → `"as of 8 Oct"`.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

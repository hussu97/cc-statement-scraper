import Foundation

/// Money into or out of a holding (`holding_flows.kind`).
public enum HoldingFlowKind: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case contribution, withdrawal, income

    public var id: String { rawValue }

    /// `"Money in"`, `"Money out"`, `"Income"`.
    public var label: String {
        switch self {
        case .contribution: "Money in"
        case .withdrawal: "Money out"
        case .income: "Income"
        }
    }

    /// Under the picker.
    public var explanation: String {
        switch self {
        case .contribution: "Money you put in: a premium, a top-up, a purchase."
        case .withdrawal: "Money you took out: a sale or a partial surrender."
        case .income: "Paid out to you and not reinvested: a dividend, a coupon, profit."
        }
    }
}

/// `rpc('holding_detail')`: a holding's active flows (with the transaction that paid each) and its
/// recorded values, newest first.
public struct HoldingDetail: Decodable, Sendable, Hashable {
    public let flows: [HoldingFlow]
    public let valuations: [HoldingValuationRecord]

    public init(flows: [HoldingFlow] = [], valuations: [HoldingValuationRecord] = []) {
        self.flows = flows
        self.valuations = valuations
    }
}

/// One flow in `holding_detail.flows`.
public struct HoldingFlow: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { flowCode }
    public let flowCode: String
    public let flowDate: CalendarDay
    public let kind: HoldingFlowKind
    /// In the holding's currency.
    public let amount: Decimal
    public let amountAed: Decimal
    /// `manual`, `rule` (linked by the payment rule), `link` (linked by hand), `holding_cost`
    /// (a metal's cost, edited on the holding), `import` (a provider sync) or `account` (a savings
    /// account's own transfer or interest).
    public let source: String
    public let notes: String?
    public let txnCode: String?
    public let txnDescription: String?
    public let txnBankCode: String?
    public let txnAccountKind: String?

    public init(flowCode: String, flowDate: CalendarDay, kind: HoldingFlowKind, amount: Decimal, amountAed: Decimal,
                source: String = "manual", notes: String? = nil, txnCode: String? = nil, txnDescription: String? = nil,
                txnBankCode: String? = nil, txnAccountKind: String? = nil) {
        self.flowCode = flowCode
        self.flowDate = flowDate
        self.kind = kind
        self.amount = amount
        self.amountAed = amountAed
        self.source = source
        self.notes = notes
        self.txnCode = txnCode
        self.txnDescription = txnDescription
        self.txnBankCode = txnBankCode
        self.txnAccountKind = txnAccountKind
    }

    /// Paid by a ledger transaction.
    public var isLinked: Bool { txnCode != nil }

    /// The payment's description, else the note, else what kind of flow it is.
    public var title: String {
        if let txnDescription, !txnDescription.isEmpty { return txnDescription }
        if let notes, !notes.isEmpty { return notes }
        return source == "holding_cost" ? "What you paid" : kind.label
    }

    /// `"Money in · ADCB card · linked by its rule"`, `"Income · added by hand"`.
    public var caption: String {
        var parts = [kind.label]
        if let bank = txnBankCode {
            parts.append(bank + (txnAccountKind == "credit_card" ? " card" : " account"))
        }
        switch source {
        case "rule": parts.append("linked by its rule")
        case "link": parts.append("linked by hand")
        case "holding_cost": parts.append("the holding's cost")
        case "import": parts.append("synced from the provider")
        case "account": parts.append("from the account")
        default: parts.append("added by hand")
        }
        return parts.joined(separator: " · ")
    }

    /// `"+USD 1,500.00"` in, `"−AED 500.00"` out, `"USD 120.00"` income (paid to you, not in or out).
    public func amountText(currency: String) -> String {
        let sign = switch kind {
        case .contribution: "+"
        case .withdrawal: "−"
        case .income: ""
        }
        return sign + MoneyFormat.amount(amount, currency: currency)
    }

    /// Income is good news; money in and out is information.
    public var amountTone: Tone { kind == .income ? .positive : .neutral }

    /// `"AED 7,345.00"` under a foreign amount; nil for an AED holding.
    public func aedText(currency: String) -> String? { currency == "AED" ? nil : MoneyFormat.aed(amountAed) }

    /// A metal's cost is edited on the holding, and a savings account's flows are its own
    /// transactions; everything else can be removed or unlinked.
    public var canRemove: Bool { source != "holding_cost" && source != "account" }
    /// The swipe action: `"Unlink"` for a paid flow, `"Remove"` for one added by hand.
    public var removeTitle: String { isLinked ? "Unlink" : "Remove" }
    /// After it: what happened to the payment.
    public var removedMessage: String {
        isLinked ? "Unlinked: the payment counts as spending again, and its rule won't link it back." : "Removed."
    }
}

/// One recorded value in `holding_detail.valuations`: a value (plan, broker) or unit price (shares).
public struct HoldingValuationRecord: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { valuationCode }
    public let valuationCode: String
    public let asOf: CalendarDay
    public let value: Decimal?
    public let unitPrice: Decimal?
    public let source: String

    public init(valuationCode: String, asOf: CalendarDay, value: Decimal? = nil, unitPrice: Decimal? = nil,
                source: String = "manual") {
        self.valuationCode = valuationCode
        self.asOf = asOf
        self.value = value
        self.unitPrice = unitPrice
        self.source = source
    }

    /// Stored by a provider sync (RL360) or a bank statement (a deposit), not entered by hand.
    public var isSynced: Bool { source == "import" }

    /// The note beside a stored value: a deposit's comes from its bank's statement, a plan's
    /// from the provider sync; nil for a value entered by hand.
    public func sourceLabel(for kind: HoldingKind) -> String? {
        guard isSynced else { return nil }
        return kind == .deposit ? "From statement" : "Synced"
    }

    /// A synced plan records a value a day: the list shows the latest few until asked for all.
    public static let listLimit = 12

    /// The values to show, newest first, and how many are left out.
    public static func visible(_ values: [HoldingValuationRecord], showAll: Bool) -> (shown: [HoldingValuationRecord], hidden: Int) {
        let shown = showAll ? values : Array(values.prefix(listLimit))
        return (shown, values.count - shown.count)
    }

    /// `"USD 53,800.00"`, or `"USD 4.10 a unit"`.
    public func text(currency: String) -> String {
        if let value { return MoneyFormat.amount(value, currency: currency) }
        if let unitPrice { return MoneyFormat.amount(unitPrice, currency: currency, fractionDigits: 4) + " a unit" }
        return "—"
    }
}

/// The Add money in / out / income form for one holding. The amount is in the holding's currency;
/// for a foreign one the AED it came to may be given, else the server converts it.
public struct FlowDraft: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let holdingName: String
    public let currency: String
    public var kind: HoldingFlowKind
    public var date: CalendarDay
    public var amount: String
    public var amountAed: String
    public var notes: String

    public init(holding: Holding, today: CalendarDay = LedgerDates.today()) {
        holdingCode = holding.holdingCode
        holdingName = holding.name
        currency = holding.currency
        kind = .contribution
        date = today
        amount = ""
        amountAed = ""
        notes = ""
    }

    /// The AED field shows for a foreign currency only.
    public var asksAed: Bool { currency != "AED" }
    public var aedNote: String {
        currency == "USD" ? "Leave it empty to convert at the 3.6725 peg." : "Leave it empty to convert at the day's market rate."
    }

    public func validate(today: CalendarDay = LedgerDates.today()) -> String? {
        let a = HoldingDraft.stripped(amount)
        guard HoldingDraft.isCost(a), let value = LedgerDecimal.parse(a), value > 0 else {
            return "Enter the amount in \(currency) as a number above 0, e.g. 2000."
        }
        let aed = HoldingDraft.stripped(amountAed)
        if asksAed, !aed.isEmpty, !(HoldingDraft.isCost(aed) && (LedgerDecimal.parse(aed) ?? 0) > 0) {
            return "Enter the AED amount as a number above 0, or leave it empty."
        }
        if today < date { return "The date can't be in the future." }
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).count > 200 { return "Keep the note to 200 characters." }
        return nil
    }

    public func submission(today: CalendarDay = LedgerDates.today()) -> FlowSubmission? {
        guard validate(today: today) == nil else { return nil }
        let aed = HoldingDraft.stripped(amountAed)
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return FlowSubmission(holdingCode: holdingCode, kind: kind, flowDate: date, amount: HoldingDraft.stripped(amount),
                              amountAed: asksAed && !aed.isEmpty ? aed : nil, notes: note.isEmpty ? nil : note)
    }

    /// `"Money in added to RL360 plan."`
    public var savedMessage: String { "\(kind.label) added to \(holdingName)." }
}

/// What `add_holding_flow` is sent.
public struct FlowSubmission: Sendable, Hashable {
    public let holdingCode: String
    public let kind: HoldingFlowKind
    public let flowDate: CalendarDay
    public let amount: String
    public let amountAed: String?
    public let notes: String?

    public init(holdingCode: String, kind: HoldingFlowKind, flowDate: CalendarDay, amount: String,
                amountAed: String? = nil, notes: String? = nil) {
        self.holdingCode = holdingCode
        self.kind = kind
        self.flowDate = flowDate
        self.amount = amount
        self.amountAed = amountAed
        self.notes = notes
    }
}

/// The Update value form: a plan's or broker account's value, or a share's unit price, as of a day.
public struct ValueDraft: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode }
    public let holdingCode: String
    public let holdingName: String
    public let kind: HoldingKind
    public let currency: String
    public var amount: String
    public var asOf: CalendarDay

    public init(holding: Holding, today: CalendarDay = LedgerDates.today()) {
        holdingCode = holding.holdingCode
        holdingName = holding.name
        kind = holding.kind
        currency = holding.currency
        amount = ""
        asOf = today
    }

    /// Shares and funds take a price per unit; the others their whole value.
    public var isUnitPrice: Bool { kind == .security }
    /// `"Value in USD"`, `"Price per unit in AED"`.
    public var fieldTitle: String { isUnitPrice ? "Price per unit in \(currency)" : "Value in \(currency)" }
    public var title: String { isUnitPrice ? "Update price" : "Update value" }
    public var note: String {
        isUnitPrice
            ? "The holding is valued at its units times this price from this day on."
            : "From the statement or the app, as of the day it was shown. It stays the value until you record a newer one."
    }

    public func validate(today: CalendarDay = LedgerDates.today()) -> String? {
        let a = HoldingDraft.stripped(amount)
        let ok = isUnitPrice ? HoldingDraft.isDecimal(a, integerDigits: 12, fractionDigits: 6) : HoldingDraft.isCost(a)
        guard ok, LedgerDecimal.parse(a) != nil else {
            return isUnitPrice ? "Enter the price per unit, e.g. 4.10." : "Enter the value in \(currency), e.g. 53800."
        }
        if today < asOf { return "The date can't be in the future." }
        return nil
    }

    public func submission(today: CalendarDay = LedgerDates.today()) -> ValueSubmission? {
        guard validate(today: today) == nil else { return nil }
        let a = HoldingDraft.stripped(amount)
        return ValueSubmission(holdingCode: holdingCode, value: isUnitPrice ? nil : a,
                               unitPrice: isUnitPrice ? a : nil, asOf: asOf)
    }

    /// `"RL360 plan's value updated."`
    public var savedMessage: String { "\(holdingName)'s \(isUnitPrice ? "price" : "value") updated." }
}

/// What `record_holding_value` is sent: exactly one of value and unit price.
public struct ValueSubmission: Sendable, Hashable {
    public let holdingCode: String
    public let value: String?
    public let unitPrice: String?
    public let asOf: CalendarDay

    public init(holdingCode: String, value: String? = nil, unitPrice: String? = nil, asOf: CalendarDay) {
        self.holdingCode = holdingCode
        self.value = value
        self.unitPrice = unitPrice
        self.asOf = asOf
    }
}

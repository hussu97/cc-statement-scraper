import Foundation

/// The Add / Edit holding form, for every kind. The kind is picked when adding (an edit keeps
/// it); then the kind's fields. Numbers stay the text the person typed; `submission` turns them
/// into `save_holding`'s decimal strings (a metal's grams to 3 places, exactly, in `Decimal`).
public struct HoldingDraft: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode ?? "new" }
    /// Nil adds a holding; set edits it.
    public let holdingCode: String?
    public var kind: HoldingKind
    public var name: String
    // Gold and silver
    public var metal: Metal
    public var weight: String
    public var unit: WeightUnit
    public var karat: GoldKarat
    public var fineness: GoldFineness
    public var purity: SilverPurity
    /// The form picked; nil follows the default (`HoldingForm.defaultForm`) as metal and karat change.
    public var chosenForm: HoldingForm?
    /// What a metal cost, in AED (the other kinds' cost is the money recorded going in).
    public var cost: String
    // Plans, broker accounts, shares and funds, deposits
    public var currency: String
    public var institution: String
    public var units: String
    public var symbol: String
    public var principal: String
    public var ratePct: String
    public var maturityOn: CalendarDay
    /// Payments whose description contains this (or, `linkExact`, is exactly this) are linked.
    public var linkPattern: String
    /// Match the whole description, case aside: a 2-character rule is then allowed.
    public var linkExact: Bool
    // Every kind
    public var hasAcquiredOn: Bool
    /// The date bought, or a deposit's start.
    public var acquiredOn: CalendarDay
    public var notes: String

    /// A new holding of `kind`: 24K gold at 999.9 weighed in grams, or AED, bought today.
    public init(today: CalendarDay = LedgerDates.today(), kind: HoldingKind = .metal) {
        self.init(code: nil, today: today, kind: kind)
    }

    private init(code: String?, today: CalendarDay, kind: HoldingKind) {
        holdingCode = code
        self.kind = kind
        name = ""
        metal = .gold
        weight = ""
        unit = .grams
        karat = .k24
        fineness = .f9999
        purity = .fine
        chosenForm = nil
        cost = ""
        currency = "AED"
        institution = ""
        units = ""
        symbol = ""
        principal = ""
        ratePct = ""
        maturityOn = today.adding(months: 12)
        linkPattern = ""
        linkExact = false
        hasAcquiredOn = false
        acquiredOn = today
        notes = ""
    }

    /// Edits `holding` as the server holds it (numbers as their decimal strings, trailing zeros dropped).
    public init(holding: Holding, today: CalendarDay = LedgerDates.today()) {
        self.init(code: holding.holdingCode, today: today, kind: holding.kind)
        name = holding.name
        metal = holding.metal ?? .gold
        weight = holding.grams.map(Self.trimmedDecimal) ?? ""
        karat = holding.karat.flatMap(GoldKarat.init(rawValue:)) ?? .k24
        fineness = holding.fineness.flatMap(GoldFineness.init(rawValue:)) ?? .f9999
        purity = holding.purity.map(SilverPurity.init) ?? .fine
        chosenForm = holding.form
        // A metal's cost is on the holding; the other kinds' is the money recorded going in.
        cost = holding.kind == .metal ? (holding.costAed.map(Self.money) ?? "") : ""
        currency = holding.currency
        institution = holding.institution ?? ""
        units = holding.units.map { Self.trimmed($0, places: 6) } ?? ""
        symbol = holding.symbol ?? ""
        principal = holding.principal.map(Self.money) ?? ""
        ratePct = holding.ratePct.map { Self.trimmed($0, places: 3) } ?? ""
        maturityOn = holding.maturityOn ?? today.adding(months: 12)
        linkPattern = holding.linkPattern ?? ""
        linkExact = holding.linkExact
        hasAcquiredOn = holding.acquiredOn != nil
        acquiredOn = holding.acquiredOn ?? today
        notes = holding.notes ?? ""
    }

    public var isEditing: Bool { holdingCode != nil }
    public var title: String { isEditing ? "Edit holding" : "Add holding" }
    public var saveLabel: String { isEditing ? "Save" : "Add" }
    /// The kind is picked when adding; an edit keeps it.
    public var canChangeKind: Bool { !isEditing }

    // MARK: What the form shows

    /// `"e.g. RL360 Quantum"`.
    public var namePlaceholder: String {
        switch kind {
        case .metal: "e.g. Ten tola bar"
        case .plan: "e.g. RL360 Quantum"
        case .broker: "e.g. IBKR account"
        case .security: "e.g. Example Co shares"
        case .deposit: "e.g. Wio 12-month deposit"
        }
    }

    /// `"e.g. Interactive Brokers"`.
    public var institutionPlaceholder: String {
        switch kind {
        case .metal, .plan: "e.g. RL360"
        case .broker: "e.g. Interactive Brokers"
        case .security: "e.g. DFM"
        case .deposit: "e.g. Wio"
        }
    }

    /// The currencies offered; one the holding already has is kept.
    public static let currencies = ["AED", "USD", "EUR", "GBP"]
    public var currencyChoices: [String] { Self.currencies.contains(currency) ? Self.currencies : Self.currencies + [currency] }
    public static let currencyNote =
        "USD converts to AED at the 3.6725 peg; other currencies at the day's market rate."

    /// A deposit always has a start date; the others may say when they were bought or started.
    public var asksDateToggle: Bool { kind != .deposit }
    /// `"Date bought"`, `"Start date"`.
    public var dateTitle: String {
        switch kind {
        case .metal: "Date bought"
        case .deposit: "Start date"
        default: "Started on"
        }
    }

    /// Under the payment rule.
    public var linkRuleNote: String {
        (linkExact
            ? "Payments whose whole description is exactly this text (capitals aside)"
            : "Payments whose description contains this text")
            + " are linked to this holding as you add them: they count as saving, not spending, and add to what it cost. You can link or unlink any payment from its transaction."
    }

    public static let linkExactTitle = "Match the whole description"
    public static let linkExactHint = "Use for short names, e.g. Wio shows RL360 as RI."

    /// The rule's shortest length: 2 when it must match the whole description, else 3.
    public var linkRuleMinimum: Int { linkExact ? 2 : 3 }

    /// After adding a plan, broker account or shares: where the value and the money in go.
    public var afterAddNote: String? {
        switch kind {
        case .plan, .broker: "Then open it to record its value and the money you've put in."
        case .security: "Then open it to record the unit price and the money you've put in."
        case .deposit: "Its value accrues each day to maturity: an estimate until the bank says otherwise."
        case .metal: nil
        }
    }

    // MARK: Validation

    /// An error sentence, or nil when the draft can be sent.
    public func validate(today: CalendarDay = LedgerDates.today()) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Give the holding a name, \(namePlaceholder)." }
        if trimmedName.count > 80 { return "Keep the name to 80 characters." }
        if let problem = kind == .metal ? validateMetal() : validateOther() { return problem }
        if sendsDate, today < acquiredOn {
            return kind == .metal ? "The date bought can't be in the future." : "The start date can't be in the future."
        }
        let rule = linkPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rule.isEmpty, !(linkRuleMinimum...60).contains(rule.count) {
            if !linkExact, rule.count == 2 {
                return "A 2-character rule must match the whole description: switch on \(Self.linkExactTitle)."
            }
            return linkExact
                ? "An exact payment rule is 2 to 60 characters, e.g. RI, or leave it empty."
                : "A payment rule is 3 to 60 characters, e.g. RL360, or leave it empty."
        }
        if notes.count > 500 { return "Keep the notes to 500 characters." }
        return nil
    }

    private func validateOther() -> String? {
        if institution.trimmingCharacters(in: .whitespacesAndNewlines).count > 80 {
            return "Keep the institution to 80 characters."
        }
        switch kind {
        case .security:
            guard Self.isDecimal(Self.stripped(units), integerDigits: 12, fractionDigits: 6),
                  let u = LedgerDecimal.parse(Self.stripped(units)), u > 0
            else { return "Enter the units you hold as a number above 0, e.g. 1000 or 12.5." }
            if symbol.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { return "Keep the symbol to 20 characters." }
        case .deposit:
            guard Self.isCost(Self.stripped(principal)), let p = LedgerDecimal.parse(Self.stripped(principal)), p > 0
            else { return "Enter the amount deposited, e.g. 100000." }
            guard Self.isDecimal(Self.stripped(ratePct), integerDigits: 3, fractionDigits: 3),
                  let r = LedgerDecimal.parse(Self.stripped(ratePct)), r <= 100
            else { return "Enter the profit rate a year in percent, e.g. 4.25." }
            if maturityOn <= acquiredOn { return "The maturity date must be after the start date." }
        default:
            break
        }
        return nil
    }

    /// Whether the date goes up: always for a deposit (its start), else when switched on.
    var sendsDate: Bool { kind == .deposit || hasAcquiredOn }

    /// The validated values, as `save_holding` takes them; nil while `validate` has a problem.
    public func submission(today: CalendarDay = LedgerDates.today()) -> HoldingSubmission? {
        guard validate(today: today) == nil else { return nil }
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = linkPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let common = (code: holdingCode, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                      date: sendsDate ? acquiredOn : nil, notes: note.isEmpty ? nil : note,
                      rule: rule.isEmpty ? nil : rule, exact: !rule.isEmpty && linkExact)
        if kind == .metal {
            guard let gramsText else { return nil }
            let costText = Self.stripped(cost)
            return HoldingSubmission(
                holdingCode: common.code, name: common.name, kind: .metal, metal: metal, grams: gramsText,
                karat: metal == .gold ? karat.rawValue : nil,
                fineness: asksFineness ? fineness.rawValue : nil,
                purity: metal == .silver ? MoneyFormat.plain(purity.value) : nil,
                form: form, costAed: costText.isEmpty ? nil : costText,
                linkPattern: common.rule, linkExact: common.exact, acquiredOn: common.date, notes: common.notes)
        }
        let inst = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return HoldingSubmission(
            holdingCode: common.code, name: common.name, kind: kind, currency: currency,
            institution: inst.isEmpty ? nil : inst,
            units: kind == .security ? Self.stripped(units) : nil,
            symbol: kind == .security && !sym.isEmpty ? sym : nil,
            principal: kind == .deposit ? Self.stripped(principal) : nil,
            ratePct: kind == .deposit ? Self.stripped(ratePct) : nil,
            maturityOn: kind == .deposit ? maturityOn : nil,
            linkPattern: common.rule, linkExact: common.exact, acquiredOn: common.date, notes: common.notes)
    }

    // MARK: Server answers

    /// The server's refusals in plain words.
    public static func message(for error: any Error) -> String {
        guard let api = error as? LedgerAPIError, case let .server(_, code, message) = api else {
            return LoadState<Bool>.message(for: error)
        }
        if api.isPermission { return ownerOnlyMessage }
        switch code {
        case "22023": return "Check the holding: \(message)."
        case "P0002": return "This holding isn't in the ledger any more. Pull to refresh."
        case "23514": return "Check the payment rule: it needs 3 characters, or 2 with \(linkExactTitle) on."
        default: return LoadState<Bool>.message(for: error)
        }
    }

    public static let ownerOnlyMessage = "Only the ledger's owners can change its investments."

    /// `"Ten tola bar added."`, `"Bangles saved."`
    public var savedMessage: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(n) \(isEditing ? "saved" : "added")."
    }

    // MARK: Helpers

    /// Grouping commas and spaces dropped.
    static func stripped(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `digits{1,12}(.d{1,2})?`: no sign, at most two decimals.
    static func isCost(_ s: String) -> Bool { isDecimal(s, integerDigits: 12, fractionDigits: 2) }

    /// Unsigned plain digits with at most `integerDigits` before the point and `fractionDigits` after.
    static func isDecimal(_ s: String, integerDigits: Int, fractionDigits: Int) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), (1...integerDigits).contains(parts[0].count),
              parts[0].allSatisfy(\.isASCIIDigit) else { return false }
        return parts.count == 1 || ((1...fractionDigits).contains(parts[1].count) && parts[1].allSatisfy(\.isASCIIDigit))
    }

    /// `116.638` → `"116.638"`, `1000` → `"1000.000"`.
    static func fixed3(_ value: Decimal) -> String {
        MoneyFormat.grouped(value, fractionDigits: 3).replacingOccurrences(of: ",", with: "")
    }

    /// `52000` → `"52000.00"`: an amount as the form shows it.
    static func money(_ value: Decimal) -> String {
        MoneyFormat.grouped(value, fractionDigits: 2).replacingOccurrences(of: ",", with: "")
    }

    /// `1000.000` → `"1000"`, `116.640` → `"116.64"`.
    static func trimmedDecimal(_ value: Decimal) -> String { trimmed(value, places: 3) }

    /// Up to `places` decimals, trailing zeros dropped: `4.250` → `"4.25"`.
    static func trimmed(_ value: Decimal, places: Int) -> String {
        var s = MoneyFormat.grouped(value, fractionDigits: places).replacingOccurrences(of: ",", with: "")
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// What `save_holding` is sent: wire-ready values from a validated `HoldingDraft`.
public struct HoldingSubmission: Sendable, Hashable {
    public let holdingCode: String?
    public let name: String
    public let kind: HoldingKind
    public let metal: Metal?
    /// Grams as a decimal string with three places (`"116.638"`).
    public let grams: String?
    public let karat: Int?
    public let fineness: Int?
    /// Silver's purity as a decimal string (`"0.999"`).
    public let purity: String?
    public let form: HoldingForm?
    /// A metal's cost, AED as a decimal string; nil when not given.
    public let costAed: String?
    public let currency: String?
    public let institution: String?
    public let units: String?
    public let symbol: String?
    public let principal: String?
    public let ratePct: String?
    public let maturityOn: CalendarDay?
    public let linkPattern: String?
    public let linkExact: Bool
    public let acquiredOn: CalendarDay?
    public let notes: String?

    public init(holdingCode: String? = nil, name: String, kind: HoldingKind = .metal, metal: Metal? = nil,
                grams: String? = nil, karat: Int? = nil, fineness: Int? = nil, purity: String? = nil,
                form: HoldingForm? = nil, costAed: String? = nil, currency: String? = nil, institution: String? = nil,
                units: String? = nil, symbol: String? = nil, principal: String? = nil, ratePct: String? = nil,
                maturityOn: CalendarDay? = nil, linkPattern: String? = nil, linkExact: Bool = false,
                acquiredOn: CalendarDay? = nil,
                notes: String? = nil) {
        self.holdingCode = holdingCode
        self.name = name
        self.kind = kind
        self.metal = metal
        self.grams = grams
        self.karat = karat
        self.fineness = fineness
        self.purity = purity
        self.form = form
        self.costAed = costAed
        self.currency = currency
        self.institution = institution
        self.units = units
        self.symbol = symbol
        self.principal = principal
        self.ratePct = ratePct
        self.maturityOn = maturityOn
        self.linkPattern = linkPattern
        self.linkExact = linkExact
        self.acquiredOn = acquiredOn
        self.notes = notes
    }
}

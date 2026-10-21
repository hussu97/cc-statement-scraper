import Foundation

/// The units a weight can be typed in. A tola is 11.6638 g (the Gulf's ten-tola bar is 116.638 g).
public enum WeightUnit: String, CaseIterable, Identifiable, Hashable, Sendable {
    case grams, kilograms, tola

    public var id: String { rawValue }

    /// The picker's segment: `"g"`, `"kg"`, `"tola"`.
    public var label: String {
        switch self {
        case .grams: "g"
        case .kilograms: "kg"
        case .tola: "tola"
        }
    }

    /// Exact in base 10.
    public var gramsPerUnit: Decimal {
        switch self {
        case .grams: 1
        case .kilograms: 1000
        case .tola: Decimal(string: "11.6638", locale: Locale(identifier: "en_US_POSIX"))!
        }
    }
}

/// Gold's karat; each is valued at its own Dubai retail rate.
public enum GoldKarat: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case k24 = 24, k22 = 22, k21 = 21, k18 = 18

    public var id: Int { rawValue }
    /// `"24K"`.
    public var label: String { "\(rawValue)K" }
}

/// A 24K bar's fineness, in parts per 10,000. The Dubai 24K rate is for 999.9; the server
/// values a lower fineness pro rata (`private.gold_fineness_factor`), never the phone.
public enum GoldFineness: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case f9999 = 9999, f9995 = 9995, f9990 = 9990, f9950 = 9950

    public var id: Int { rawValue }
    /// `"999.9"`, `"999.5"`, `"999"`, `"995"`.
    public var label: String {
        switch self {
        case .f9999: "999.9"
        case .f9995: "999.5"
        case .f9990: "999"
        case .f9950: "995"
        }
    }
}

/// Silver's fine share (`holdings.purity`), as a decimal (`0.999`).
public struct SilverPurity: Hashable, Sendable, Identifiable {
    public let value: Decimal
    public var id: String { MoneyFormat.plain(value) }

    public init(_ value: Decimal) { self.value = value }

    public static let fine = SilverPurity(Decimal(string: "0.999", locale: Locale(identifier: "en_US_POSIX"))!)
    public static let britannia = SilverPurity(Decimal(string: "0.958", locale: Locale(identifier: "en_US_POSIX"))!)
    public static let sterling = SilverPurity(Decimal(string: "0.925", locale: Locale(identifier: "en_US_POSIX"))!)
    public static let coin = SilverPurity(Decimal(string: "0.9", locale: Locale(identifier: "en_US_POSIX"))!)
    public static let standard: [SilverPurity] = [.fine, .britannia, .sterling, .coin]

    /// Parts per thousand: `"999"`, `"925"`, `"999.9"`.
    public var millesimal: String {
        var s = MoneyFormat.grouped(value * 1000, fractionDigits: 1)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    /// `"999 fine"`, `"925 sterling"`.
    public var label: String {
        switch self {
        case .fine: "999 fine"
        case .britannia: "958 Britannia"
        case .sterling: "925 sterling"
        case .coin: "900 coin"
        default: millesimal
        }
    }

    /// The standard purities, plus `current` when a holding has another one (set on the web).
    public static func choices(including current: SilverPurity) -> [SilverPurity] {
        standard.contains(current) ? standard : standard + [current]
    }
}

/// The Add / Edit holding form. Weights and the cost stay the text the person typed; `submission`
/// turns them into `save_holding`'s decimal strings (grams to 3 places, exactly, in `Decimal`).
public struct HoldingDraft: Sendable, Hashable, Identifiable {
    public var id: String { holdingCode ?? "new" }
    /// Nil adds a holding; set edits it.
    public let holdingCode: String?
    public var name: String
    public var metal: Metal
    public var weight: String
    public var unit: WeightUnit
    public var karat: GoldKarat
    public var fineness: GoldFineness
    public var purity: SilverPurity
    /// The form picked; nil follows the default (`HoldingForm.defaultForm`) as metal and karat change.
    public var chosenForm: HoldingForm?
    public var cost: String
    public var hasAcquiredOn: Bool
    public var acquiredOn: CalendarDay
    public var notes: String

    /// A new holding: 24K gold at 999.9, weighed in grams, bought today.
    public init(today: CalendarDay = LedgerDates.today()) {
        holdingCode = nil
        name = ""
        metal = .gold
        weight = ""
        unit = .grams
        karat = .k24
        fineness = .f9999
        purity = .fine
        chosenForm = nil
        cost = ""
        hasAcquiredOn = false
        acquiredOn = today
        notes = ""
    }

    /// Edits `holding` as the server holds it (grams, cost and purity as their decimal strings).
    public init(holding: Holding, today: CalendarDay = LedgerDates.today()) {
        holdingCode = holding.holdingCode
        name = holding.name
        metal = holding.metal
        weight = Self.trimmedDecimal(holding.grams)
        unit = .grams
        karat = holding.karat.flatMap(GoldKarat.init(rawValue:)) ?? .k24
        fineness = holding.fineness.flatMap(GoldFineness.init(rawValue:)) ?? .f9999
        purity = holding.purity.map(SilverPurity.init) ?? .fine
        chosenForm = holding.form
        cost = holding.costAed.map { MoneyFormat.grouped($0, fractionDigits: 2).replacingOccurrences(of: ",", with: "") } ?? ""
        hasAcquiredOn = holding.acquiredOn != nil
        acquiredOn = holding.acquiredOn ?? today
        notes = holding.notes ?? ""
    }

    public var isEditing: Bool { holdingCode != nil }
    public var title: String { isEditing ? "Edit holding" : "Add holding" }
    public var saveLabel: String { isEditing ? "Save" : "Add" }
    /// Bar, coin or jewellery: the one picked when this metal allows it, else the default for the
    /// metal and karat (silver jewellery falls back to a bar). The picker binds to it.
    public var form: HoldingForm {
        get {
            if let chosenForm, chosenForm.isAllowed(for: metal) { return chosenForm }
            return HoldingForm.defaultForm(metal: metal, karat: metal == .gold ? karat.rawValue : nil)
        }
        set { chosenForm = newValue }
    }

    /// The form picker's choices: no jewellery for silver.
    public var formChoices: [HoldingForm] { HoldingForm.choices(for: metal) }
    /// The sheet's header photo.
    public func imageURL(supabaseURL: URL?) -> URL? {
        HoldingImage.url(imagePath: form.imagePath(metal: metal), supabaseURL: supabaseURL)
    }
    public var imageLabel: String { form.imageLabel(metal: metal) }

    /// Fineness is asked for 24K gold only.
    public var asksFineness: Bool { metal == .gold && karat == .k24 }

    // MARK: Weight

    /// The weight in grams, rounded half-up to 3 places; nil when the text isn't a positive number.
    public var grams: Decimal? {
        guard let typed = LedgerDecimal.parse(Self.stripped(weight)), typed > 0 else { return nil }
        return MoneyFormat.rounded(typed * unit.gramsPerUnit, scale: 3)
    }

    /// What is sent: `"116.638"`.
    public var gramsText: String? { grams.map(Self.fixed3) }

    /// Under the weight when it isn't typed in grams: `"= 116.638 g"`.
    public var gramsPreview: String? {
        guard unit != .grams, let grams, grams > 0 else { return nil }
        return "= " + HoldingsText.weight(grams)
    }

    // MARK: Validation

    /// An error sentence, or nil when the draft can be sent.
    public func validate(today: CalendarDay = LedgerDates.today()) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Give the holding a name, e.g. Ten tola bar." }
        if trimmedName.count > 80 { return "Keep the name to 80 characters." }
        guard let grams else { return "Enter the weight as a number above 0, e.g. 116.64 or 10." }
        if grams <= 0 { return "The weight is under 0.001 g." }
        if grams >= 100_000_000_000 { return "That weight is too large." }
        if !Self.stripped(cost).isEmpty, !Self.isCost(Self.stripped(cost)) {
            return "Enter what you paid in AED, e.g. 52000, or leave it empty."
        }
        if !form.isAllowed(for: metal) { return "Silver is a bar or a coin." }
        if hasAcquiredOn, today < acquiredOn { return "The date bought can't be in the future." }
        if notes.count > 500 { return "Keep the notes to 500 characters." }
        return nil
    }

    /// The validated values, as `save_holding` takes them; nil while `validate` has a problem.
    public func submission(today: CalendarDay = LedgerDates.today()) -> HoldingSubmission? {
        guard validate(today: today) == nil, let gramsText else { return nil }
        let costText = Self.stripped(cost)
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return HoldingSubmission(
            holdingCode: holdingCode,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            metal: metal,
            grams: gramsText,
            karat: metal == .gold ? karat.rawValue : nil,
            fineness: asksFineness ? fineness.rawValue : nil,
            purity: metal == .silver ? MoneyFormat.plain(purity.value) : nil,
            form: form,
            costAed: costText.isEmpty ? nil : costText,
            acquiredOn: hasAcquiredOn ? acquiredOn : nil,
            notes: note.isEmpty ? nil : note)
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
    static func isCost(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), (1...12).contains(parts[0].count),
              parts[0].allSatisfy(\.isASCIIDigit) else { return false }
        return parts.count == 1 || ((1...2).contains(parts[1].count) && parts[1].allSatisfy(\.isASCIIDigit))
    }

    /// `116.638` → `"116.638"`, `1000` → `"1000.000"`.
    static func fixed3(_ value: Decimal) -> String {
        MoneyFormat.grouped(value, fractionDigits: 3).replacingOccurrences(of: ",", with: "")
    }

    /// `1000.000` → `"1000"`, `116.640` → `"116.64"`.
    static func trimmedDecimal(_ value: Decimal) -> String {
        var s = fixed3(value)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

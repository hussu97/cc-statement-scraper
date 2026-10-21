import Foundation

/// The gold and silver part of the holding form: form and photo, fineness, the weight in grams.
extension HoldingDraft {
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

    func validateMetal() -> String? {
        guard let grams else { return "Enter the weight as a number above 0, e.g. 116.64 or 10." }
        if grams <= 0 { return "The weight is under 0.001 g." }
        if grams >= 100_000_000_000 { return "That weight is too large." }
        if !Self.stripped(cost).isEmpty, !Self.isCost(Self.stripped(cost)) {
            return "Enter what you paid in AED, e.g. 52000, or leave it empty."
        }
        if !form.isAllowed(for: metal) { return "Silver is a bar or a coin." }
        return nil
    }
}

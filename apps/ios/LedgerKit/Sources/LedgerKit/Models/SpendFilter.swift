import Foundation
import Supabase

/// Insights' Monthly spend filter: which spend the chart counts, before it is
/// split. `spend_series` and `spend_breakdown` take it as optional arrays plus
/// a search (migration 20261010001600): AND across kinds, OR within one, and
/// an empty kind means all. `instrument` narrows to credit- or debit-card spend (Phase 2c's
/// `p_instruments`; nil is both).
public struct SpendFilter: Sendable, Hashable {
    /// The category "code" for spend with no category (`spend_breakdown`'s key).
    public static let uncategorized = SpendBreakdown.uncategorizedKey

    public var categoryCodes: Set<String>
    public var bankCodes: Set<String>
    public var cardCodes: Set<String>
    /// Merchant name or description; sent trimmed, the server cleans it.
    public var search: String
    /// Credit or debit cards only; nil: both.
    public var instrument: SpendInstrument?

    public init(categoryCodes: Set<String> = [], bankCodes: Set<String> = [], cardCodes: Set<String> = [],
                search: String = "", instrument: SpendInstrument? = nil) {
        self.categoryCodes = categoryCodes
        self.bankCodes = bankCodes
        self.cardCodes = cardCodes
        self.search = search
        self.instrument = instrument
    }

    public var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isEmpty: Bool {
        categoryCodes.isEmpty && bankCodes.isEmpty && cardCodes.isEmpty && trimmedSearch.isEmpty && instrument == nil
    }

    /// How many filters are on (each selection, the search and the card type count once): the button's badge.
    public var activeCount: Int {
        categoryCodes.count + bankCodes.count + cardCodes.count + (trimmedSearch.isEmpty ? 0 : 1)
            + (instrument == nil ? 0 : 1)
    }

    /// The filter arguments of both RPCs: null for an unused kind, codes
    /// sorted so the same filter always sends the same request. `p_instruments`
    /// goes only when a card type is chosen, so "both" asks exactly what a server
    /// from before it (20261020130318) answers.
    public var rpcParams: [String: AnyJSON] {
        func codes(_ set: Set<String>) -> AnyJSON {
            set.isEmpty ? .null : .array(set.sorted().map(AnyJSON.string))
        }
        let q = trimmedSearch
        var params: [String: AnyJSON] = [
            "p_category_codes": codes(categoryCodes),
            "p_bank_codes": codes(bankCodes),
            "p_card_codes": codes(cardCodes),
            "p_q": q.isEmpty ? .null : .string(q),
        ]
        if let instrument { params["p_instruments"] = .array([.string(instrument.rawValue)]) }
        return params
    }

    /// `"Dining, Groceries · FAB · •9206 · “careem”"`; nil when nothing is
    /// filtered. Names come from `options` in their order; a code it doesn't
    /// know (options not loaded yet) shows as itself, after the known ones.
    public func summary(options: SpendFilterOptions?) -> String? {
        guard !isEmpty else { return nil }
        func labels(_ selected: Set<String>, _ list: [SpendFilterOptions.Option]) -> String? {
            guard !selected.isEmpty else { return nil }
            let known = list.filter { selected.contains($0.code) }
            let unknown = selected.subtracting(known.map(\.code)).sorted()
            return (known.map(\.label) + unknown).joined(separator: ", ")
        }
        let parts = [
            labels(categoryCodes, options?.categories ?? [SpendFilterOptions.uncategorizedOption]),
            labels(bankCodes, options?.banks ?? []),
            labels(cardCodes, options?.cards ?? []),
            trimmedSearch.isEmpty ? nil : "“\(trimmedSearch)”",
            instrument?.summaryLabel,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// Adds the code if absent, removes it if present.
    public static func toggle(_ code: String, in set: inout Set<String>) {
        if set.remove(code) == nil { set.insert(code) }
    }
}

/// Which cards' spend counts (`v_spend.instrument`).
public enum SpendInstrument: String, Sendable, Hashable, CaseIterable, Identifiable {
    case creditCard = "credit_card"
    case debitCard = "debit_card"

    public var id: String { rawValue }

    /// The segmented control's label: `"Credit"` / `"Debit"` (`"All cards"` is nil).
    public var label: String { self == .creditCard ? "Credit" : "Debit" }

    /// In the filter summary: `"Credit cards"` / `"Debit cards"`.
    public var summaryLabel: String { self == .creditCard ? "Credit cards" : "Debit cards" }

    /// The control's choices, `"All cards"` first.
    public static let choices: [(instrument: SpendInstrument?, label: String)] =
        [(nil, "All cards")] + allCases.map { ($0, $0.label) }
}

/// What the filter sheet offers, from `filter_meta`.
public struct SpendFilterOptions: Sendable, Hashable {
    public struct Option: Sendable, Hashable, Identifiable {
        public var id: String { code }
        public let code: String
        public let label: String
        /// A second line (a bank's full name, a supplementary card).
        public let detail: String?
        /// A category's colour token; nil elsewhere.
        public let colorToken: String?
    }

    public static let uncategorizedOption = Option(code: SpendFilter.uncategorized, label: "Uncategorised",
                                                   detail: nil, colorToken: nil)
    /// Category kinds `v_spend` never counts, so filtering by them would always be empty.
    static let nonSpendKinds: Set<String> = ["transfer", "ignore", "income", "saving", "support"]

    public let categories: [Option]
    public let banks: [Option]
    public let cards: [Option]

    /// Categories spend can carry (not archived, not transfer/ignore/income/saving/support), in the server's order, then
    /// Uncategorised; banks by code; cards as `"•9206"` with their bank.
    public init(meta: FilterMeta) {
        categories = meta.categories.filter { !$0.archived && !Self.nonSpendKinds.contains($0.kind) }.map {
            Option(code: $0.categoryCode, label: $0.name, detail: nil, colorToken: $0.colorToken)
        } + [Self.uncategorizedOption]
        banks = meta.banks.sorted { $0.bankCode < $1.bankCode }.map {
            Option(code: $0.bankCode, label: $0.bankCode, detail: $0.name == $0.bankCode ? nil : $0.name, colorToken: nil)
        }
        cards = meta.cards.sorted { ($0.bankCode, $0.last4) < ($1.bankCode, $1.last4) }.map {
            Option(code: $0.cardCode, label: "•\($0.last4)",
                   detail: $0.isSupplementary ? "\($0.bankCode) · supplementary" : $0.bankCode, colorToken: nil)
        }
    }
}

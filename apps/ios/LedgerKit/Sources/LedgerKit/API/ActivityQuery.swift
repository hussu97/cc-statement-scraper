import Foundation

/// Activity's filters, as the PostgREST filters they become. Pure, so the
/// encoding (the part that breaks on a comma in a merchant name) is testable.
public struct ActivityQuery: Sendable, Hashable {
    /// No `pending` or `posted`: an SMS or payment charge is a transaction like
    /// any other, so the filter never sets it apart ("Posted" would hide it).
    public enum StatusFilter: String, Sendable, CaseIterable, Identifiable {
        case all, void, orphaned
        public var id: String { rawValue }
        public var label: String { self == .all ? "Any status" : rawValue.capitalized }
    }

    /// Where a transaction's evidence came from (the web's `source` filter):
    /// SMS only, a statement only, or both.
    public enum SourceFilter: String, Sendable, CaseIterable, Identifiable {
        case all, sms, statement, both
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .all: "Any source"
            case .sms: "SMS only"
            case .statement: "Statement only"
            case .both: "SMS + statement"
            }
        }
    }

    /// The one page size (CLAUDE.md §4.5): 100, options up to 2000. Paging
    /// itself is `Paginator`'s (`PageRequest`); the query is only the filters.
    public static let defaultPageSize = 100
    public static let pageSizeOptions = [100, 200, 500, 1000, 2000]

    public var search: String = ""
    public var accountCode: String?
    /// One card of the ledger (`cards.card_code`); `setAccount` clears it.
    public var cardCode: String?
    public var categoryCode: String?
    public var uncategorizedOnly = false
    public var status: StatusFilter = .all
    public var source: SourceFilter = .all
    public var from: CalendarDay?
    public var to: CalendarDay?

    public init() {}

    /// The month's uncategorised transactions: Overview's "N uncategorised this
    /// month" and the `ledger://uncategorised` link.
    public static func uncategorised(month: CalendarDay) -> ActivityQuery {
        var query = ActivityQuery()
        query.uncategorizedOnly = true
        query.month = month
        return query
    }

    public var hasFilters: Bool { filterCount > 0 }

    /// How many filters narrow the list, the search aside (the toolbar's
    /// "Filters, 3 active"). A date range counts once, like the web's chip.
    public var filterCount: Int {
        [accountCode != nil, cardCode != nil, categoryCode != nil || uncategorizedOnly, status != .all,
         source != .all, from != nil || to != nil].filter { $0 }.count
    }

    /// A new account filter drops the card filter, as the web's does: the card
    /// may belong to another account.
    public mutating func setAccount(_ code: String?) {
        guard code != accountCode else { return }
        accountCode = code
        cardCode = nil
    }

    /// Resets every filter but keeps the search text.
    public mutating func clearFilters() {
        let search = self.search
        self = ActivityQuery()
        self.search = search
    }

    /// A whole-month date filter: `from` the 1st `to` the last day. Reads nil
    /// for no date filter or a range that is not exactly one month.
    public var month: CalendarDay? {
        get {
            guard let from, let to, from.day == 1, to == from.endOfMonth else { return nil }
            return from
        }
        set {
            from = newValue?.startOfMonth
            to = newValue?.endOfMonth
        }
    }

    /// Whether a row still belongs under the category filters after the
    /// reader recategorised it (the list drops it otherwise).
    public func keeps(categoryCode rowCategory: String?) -> Bool {
        if uncategorizedOnly { return rowCategory == nil }
        if let categoryCode { return rowCategory == categoryCode }
        return true
    }

    /// The PostgREST `or=(…)` body for a free-text search over description and
    /// merchant name, or nil when the search is blank.
    ///
    /// PostgREST splits on `,` and treats `()` specially inside `or`, and `*` is
    /// its wildcard, so those are replaced with the single-character wildcard
    /// `_` rather than escaped (PostgREST has no escape inside `or`). `%` and `_`
    /// are ILIKE metacharacters and are escaped with a backslash.
    public var searchOrFilter: String? {
        let term = Self.sanitizedSearch(search)
        guard !term.isEmpty else { return nil }
        return "description.ilike.*\(term)*,merchant_name.ilike.*\(term)*"
    }

    static func sanitizedSearch(_ raw: String) -> String {
        var out = ""
        for ch in raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80) {
            switch ch {
            case ",", "(", ")", "*", ":", "\"": out.append("_")
            case "%": out.append("\\%")
            case "_": out.append("\\_")
            case "\\": out.append("\\\\")
            default: out.append(ch)
            }
        }
        return out
    }
}

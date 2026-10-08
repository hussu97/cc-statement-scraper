import Foundation

/// Activity's filters, as the PostgREST filters they become. Pure, so the
/// encoding (the part that breaks on a comma in a merchant name) is testable.
public struct ActivityQuery: Sendable, Hashable {
    public enum StatusFilter: String, Sendable, CaseIterable, Identifiable {
        case all, pending, posted, orphaned
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// The one page size (CLAUDE.md §4.5): 100, options up to 2000.
    public static let defaultPageSize = 100
    public static let pageSizeOptions = [100, 200, 500, 1000, 2000]

    public var search: String = ""
    public var accountCode: String?
    public var categoryCode: String?
    public var uncategorizedOnly = false
    public var status: StatusFilter = .all
    public var from: CalendarDay?
    public var to: CalendarDay?
    public var page = 0
    public var pageSize = ActivityQuery.defaultPageSize

    public init() {}

    public var hasFilters: Bool {
        accountCode != nil || categoryCode != nil || uncategorizedOnly || status != .all || from != nil || to != nil
    }

    /// Resets every filter but keeps the search text.
    public mutating func clearFilters() {
        let search = self.search
        self = ActivityQuery()
        self.search = search
    }

    public var rangeStart: Int { page * pageSize }
    public var rangeEnd: Int { rangeStart + pageSize - 1 }

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

import Foundation

/// `rpc('spend_breakdown')`: monthly spend split by category, bank or merchant,
/// top N groups plus `__other__` ("Others", always last). Every month of the
/// range is listed and every series row carries every group key, zero-filled.
/// An empty range has `groups: []` and `values: {}`.
///
/// Group keys are codes (`cat_01…`, `FAB`, `mer_01…`) that must reach the
/// screen byte for byte, so this type is decoded with `SpendBreakdown.decode(_:)`
/// (explicit wire keys, no key strategy) rather than trusting every Foundation
/// release to leave `LedgerJSON`'s snake-case conversion off dictionary keys.
public struct SpendBreakdown: Decodable, Sendable, Hashable {
    public static let otherKey = "__other__"
    public static let uncategorizedKey = "__uncategorized__"
    public static let unknownMerchantKey = "__unknown__"

    public let groupBy: String
    public let total: Decimal
    /// `"2026-05"` … `"2026-10"`, oldest first.
    public let months: [String]
    public let groups: [Group]
    public let series: [Month]

    public struct Group: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { key }
        public let key: String
        public let label: String
        public let colorToken: String?
        public let logoPath: String?
        public let total: Decimal
        /// Of the range total, 0…1 (4 dp, clamped by the server).
        public let share: Decimal

        enum CodingKeys: String, CodingKey {
            case key, label, total, share
            case colorToken = "color_token", logoPath = "logo_path"
        }

        public var isOther: Bool { key == SpendBreakdown.otherKey }
    }

    public struct Month: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { month }
        public let month: String
        public let total: Decimal
        public let values: [String: Decimal]

        enum CodingKeys: String, CodingKey { case month, total, values }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            month = try c.decode(String.self, forKey: .month)
            total = try c.decode(Decimal.self, forKey: .total)
            let raw = try c.decodeIfPresent([String: DecimalValue].self, forKey: .values) ?? [:]
            values = raw.mapValues(\.value)
        }

        public init(month: String, total: Decimal, values: [String: Decimal]) {
            self.month = month
            self.total = total
            self.values = values
        }
    }

    enum CodingKeys: String, CodingKey {
        case total, months, groups, series
        case groupBy = "group_by"
    }

    /// The only way to read the RPC's bytes (see the type comment).
    public static func decode(_ data: Data) throws -> SpendBreakdown {
        try JSONDecoder().decode(SpendBreakdown.self, from: data)
    }
}

/// The Monthly spend split control: None draws the plain `spend_series` bars.
public enum SpendSplitGrouping: String, CaseIterable, Identifiable, Sendable {
    case none, category, bank, merchant
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: "None"
        case .category: "Category"
        case .bank: "Bank"
        case .merchant: "Merchant"
        }
    }
}

/// One stacked segment: a group's spend in a month.
public struct SpendSegment: Sendable, Hashable, Identifiable {
    public var id: String { month + "|" + groupKey }
    public let month: String
    public let monthLabel: String
    public let groupKey: String
    public let groupLabel: String
    public let colorToken: String?
    public let amount: Decimal
}

/// The selection callout: the month's total and each group's slice of it.
public struct SpendCallout: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String { key }
        public let key: String
        public let label: String
        public let colorToken: String?
        public let amount: String
        public let share: String?
    }
    public let title: String
    public let total: String
    public let rows: [Row]
}

extension SpendBreakdown {
    /// The colour token of a group: a category's own `color_token`; banks and
    /// merchants take the chart palette in rank order; Others is grey (nil).
    public func colorToken(for group: Group) -> String? {
        if group.isOther { return nil }
        if groupBy == "category" { return group.colorToken }
        let index = groups.firstIndex(of: group) ?? 0
        return "cat-\(index % 12 + 1)"
    }

    /// `"Oct"`; `"Oct 25"` when the range repeats a month name.
    public func monthLabel(_ month: String) -> String {
        guard let day = CalendarDay(iso: month + "-01") else { return month }
        let abbrevs = months.compactMap { CalendarDay(iso: $0 + "-01").map(LedgerDates.monthAbbrev) }
        let label = LedgerDates.monthAbbrev(day)
        if Set(abbrevs).count < abbrevs.count { return "\(label) \(String(format: "%02d", day.year % 100))" }
        return label
    }

    /// Every non-zero segment, months oldest first and groups in rank order
    /// (the stacking order).
    public var segments: [SpendSegment] {
        series.flatMap { month in
            groups.compactMap { group -> SpendSegment? in
                guard let amount = month.values[group.key], amount != 0 else { return nil }
                return SpendSegment(month: month.month, monthLabel: monthLabel(month.month), groupKey: group.key,
                                    groupLabel: group.label, colorToken: colorToken(for: group), amount: amount)
            }
        }
    }

    /// Month labels on the x axis, in order (months without spend included).
    public var monthLabels: [String] { months.map(monthLabel) }

    public var isEmpty: Bool { groups.isEmpty }

    /// The callout for a month label the chart selected.
    public func callout(forMonthLabel label: String) -> SpendCallout? {
        guard let month = series.first(where: { monthLabel($0.month) == label }) else { return nil }
        let title = CalendarDay(iso: month.month + "-01").map(LedgerDates.monthTitle) ?? month.month
        let rows = groups.compactMap { group -> SpendCallout.Row? in
            guard let amount = month.values[group.key], amount != 0 else { return nil }
            // A slice of the month's server total; no share when the month nets to ≤ 0.
            let share = month.total > 0 ? MoneyFormat.percent(amount / month.total) : nil
            return .init(key: group.key, label: group.label, colorToken: colorToken(for: group),
                         amount: MoneyFormat.aed(amount, fractionDigits: 0), share: share)
        }
        return SpendCallout(title: title, total: MoneyFormat.aed(month.total, fractionDigits: 0), rows: rows)
    }

    /// `"42%"`, or `"0.4%"` for a sliver that would round to 0%.
    public static func shareLabel(_ share: Decimal) -> String {
        let whole = MoneyFormat.percent(share)
        return whole == "0%" && share > 0 ? MoneyFormat.percent(share, fractionDigits: 1) : whole
    }

    /// The group is a bank (its key is the bank code), so it can show a logo.
    public var showsBankLogos: Bool { groupBy == "bank" }
}

import Foundation

/// The Activity date filter's quick picks, as the web's `RANGE_PRESETS`
/// (`apps/web/src/lib/dates.ts`) builds them from today's Dubai date.
public enum ActivityDatePreset: String, Sendable, CaseIterable, Identifiable {
    case thisMonth, lastMonth, last3Months, yearToDate

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .last3Months: "Last 3 months"
        case .yearToDate: "This year"
        }
    }

    /// This month and the last 3 months run to the month's last day (a pending
    /// alert dated tomorrow still shows); the year runs to today.
    public func range(today: CalendarDay = LedgerDates.today()) -> (from: CalendarDay, to: CalendarDay) {
        let month = today.startOfMonth
        switch self {
        case .thisMonth: return (month, month.endOfMonth)
        case .lastMonth: return (month.adding(months: -1), month.adding(days: -1))
        case .last3Months: return (month.adding(months: -2), month.endOfMonth)
        case .yearToDate: return (CalendarDay(year: today.year, month: 1, day: 1), today)
        }
    }
}

/// The filter sheet's date choice: no date filter, a preset, or a custom range.
public enum ActivityDateChoice: Hashable, Sendable {
    case any
    case preset(ActivityDatePreset)
    case custom

    public var label: String {
        switch self {
        case .any: "Any time"
        case .preset(let preset): preset.label
        case .custom: "Custom range"
        }
    }

    /// Every choice, in the sheet's order.
    public static let all: [ActivityDateChoice] = [.any] + ActivityDatePreset.allCases.map { .preset($0) } + [.custom]
}

extension ActivityQuery {
    /// What the date filter is: a preset when the range is exactly one, else custom.
    public func dateChoice(today: CalendarDay = LedgerDates.today()) -> ActivityDateChoice {
        guard from != nil || to != nil else { return .any }
        for preset in ActivityDatePreset.allCases {
            let range = preset.range(today: today)
            if from == range.from && to == range.to { return .preset(preset) }
        }
        return .custom
    }

    /// Picks a date choice. Custom keeps a range already set and otherwise
    /// starts at this month so far, for the reader to adjust.
    public mutating func choose(_ choice: ActivityDateChoice, today: CalendarDay = LedgerDates.today()) {
        switch choice {
        case .any:
            from = nil
            to = nil
        case .preset(let preset):
            (from, to) = preset.range(today: today)
        case .custom:
            if from == nil && to == nil { (from, to) = (today.startOfMonth, today) }
        }
    }

    /// A custom range; reversed ends swap, as the web's URL parser does.
    public mutating func setRange(from newFrom: CalendarDay?, to newTo: CalendarDay?) {
        if let a = newFrom, let b = newTo, a > b {
            (from, to) = (b, a)
        } else {
            (from, to) = (newFrom, newTo)
        }
    }

    /// `"This month"`, `"1 Sep 2026 – 14 Oct 2026"`, `"From 1 Sep 2026"`; nil with no date filter.
    public func dateLabel(today: CalendarDay = LedgerDates.today()) -> String? {
        switch dateChoice(today: today) {
        case .any: return nil
        case .preset(let preset): return preset.label
        case .custom:
            switch (from, to) {
            case let (a?, b?): return "\(LedgerDates.fullDayLabel(a)) – \(LedgerDates.fullDayLabel(b))"
            case let (a?, nil): return "From \(LedgerDates.fullDayLabel(a))"
            case let (nil, b?): return "Until \(LedgerDates.fullDayLabel(b))"
            case (nil, nil): return nil
            }
        }
    }

    /// One PostgREST filter on `v_transactions`.
    public enum RestFilter: Hashable, Sendable {
        case eq(String, String)
        case isTrue(String)
        case isFalse(String)
        case isNull(String)
        case gte(String, String)
        case lte(String, String)
        case or(String)
    }

    /// The `v_transactions` filters for these settings, in the web's order and
    /// meaning (`applyActivityFilters` in `apps/web/src/data/transactions.ts`).
    public var restFilters: [RestFilter] {
        var out: [RestFilter] = []
        if let from { out.append(.gte("txn_date", from.iso)) }
        if let to { out.append(.lte("txn_date", to.iso)) }
        if let accountCode { out.append(.eq("account_code", accountCode)) }
        if let cardCode { out.append(.eq("card_code", cardCode)) }
        if uncategorizedOnly {
            out.append(.isNull("category_code"))
        } else if let categoryCode {
            out.append(.eq("category_code", categoryCode))
        }
        if status != .all { out.append(.eq("status", status.rawValue)) }
        switch source {
        case .all: break
        case .sms: out += [.isTrue("has_sms"), .isFalse("has_statement")]
        case .statement: out += [.isTrue("has_statement"), .isFalse("has_sms")]
        case .both: out += [.isTrue("has_sms"), .isTrue("has_statement")]
        }
        if let searchOrFilter { out.append(.or(searchOrFilter)) }
        return out
    }

    /// The filters as the web's `activityFilter` object: the `p_filter` that
    /// `activity_day_totals` (and the bulk RPCs) read with
    /// `private.activity_selection`. Only set keys; a blank search is dropped.
    public var activityFilter: [String: String] {
        var out: [String: String] = [:]
        if let from { out["from"] = from.iso }
        if let to { out["to"] = to.iso }
        if let accountCode { out["account"] = accountCode }
        if let cardCode { out["card"] = cardCode }
        if uncategorizedOnly {
            out["category"] = "none"
        } else if let categoryCode {
            out["category"] = categoryCode
        }
        if status != .all { out["status"] = status.rawValue }
        if source != .all { out["source"] = source.rawValue }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { out["q"] = q }
        return out
    }
}

extension FilterMeta {
    /// The card filter's choices: the account's cards when one is chosen, else all.
    public func cards(forAccount accountCode: String?) -> [CardOption] {
        guard let accountCode else { return cards }
        return cards.filter { $0.accountCode == accountCode }
    }
}

extension FilterMeta.CardOption {
    /// `"FAB •1234"`, `"FAB •1234 (supp.)"`, as the web's card filter says it.
    public var label: String { "\(bankCode) •\(last4)" + (isSupplementary ? " (supp.)" : "") }
}

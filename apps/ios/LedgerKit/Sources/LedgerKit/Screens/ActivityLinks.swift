import Foundation

/// Where other screens send the reader in Activity (PAR-4), as the web's links
/// into `/activity` do: each is an `ActivityQuery` handed to
/// `TabRouter.openActivity`.
extension ActivityQuery {
    /// Every pending transaction, any date (Overview's pending strip; the web's `?status=pending`).
    public static func pending() -> ActivityQuery {
        var query = ActivityQuery()
        query.status = .pending
        return query
    }

    /// One merchant's transactions in a range: its name as the search, as the
    /// web's merchant links do. Nil for a blank name.
    public static func merchant(_ name: String, from: CalendarDay, to: CalendarDay,
                                categoryCode: String? = nil) -> ActivityQuery? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var query = ActivityQuery()
        query.search = String(trimmed.prefix(120))
        query.setRange(from: from, to: to)
        query.categoryCode = categoryCode
        return query
    }
}

extension Overview {
    /// "N uncategorised this month": that month's uncategorised transactions.
    public var uncategorisedActivity: ActivityQuery { .uncategorised(month: month) }
    /// The pending strip: every pending transaction.
    public var pendingActivity: ActivityQuery { .pending() }
}

extension MerchantSpend {
    /// A leaderboard row's transactions in the range shown; nil for the
    /// unknown-merchant bucket, which no search can find.
    public func activityQuery(from: CalendarDay, to: CalendarDay) -> ActivityQuery? {
        guard merchantCode != nil else { return nil }
        return .merchant(merchantName, from: from, to: to)
    }
}

extension CategoryDrillDownRequest {
    /// "See transactions" on a category's drill-down: that category (or the
    /// uncategorised bucket) over the range shown, as the web's category view links.
    public var activityQuery: ActivityQuery {
        var query = ActivityQuery()
        if let code = target.categoryCode {
            query.categoryCode = code
        } else {
            query.uncategorizedOnly = true
        }
        query.setRange(from: from, to: to)
        return query
    }
}

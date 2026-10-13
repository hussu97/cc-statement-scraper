import Foundation

/// Trends' grouping: the web's "Group by" (Total, Category, Bank, Merchant, Account, Card).
/// Bank comes from `spend_breakdown`, which is monthly; the rest from `spend_series`.
public enum TrendsGroup: String, CaseIterable, Identifiable, Sendable {
    case total, category, bank, merchant, account, card

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .total: "Total"
        case .category: "Category"
        case .bank: "Bank"
        case .merchant: "Merchant"
        case .account: "Account"
        case .card: "Card"
        }
    }

    /// `spend_series`'s `p_group`; nil for Bank, which `spend_series` can't group by.
    public var seriesGroup: SpendGroup? {
        switch self {
        case .total: SpendGroup.none
        case .category: .category
        case .bank: nil
        case .merchant: .merchant
        case .account: .account
        case .card: .card
        }
    }

    /// Bank splits come from `spend_breakdown`, which buckets by month only.
    public var monthlyOnly: Bool { self == .bank }
}

/// What the Trends chart and table draw: every bucket of the range (oldest first) with the
/// server's total, and each group's slice of it. Shaping only; every figure is the server's.
public struct TrendsSeries: Sendable, Hashable {
    /// The filter this series was fetched with. Links use it, not the screen's current filter,
    /// which may already be newer while this series is still on screen (loading or failed).
    public var filter = SpendFilter()

    public struct Group: Sendable, Hashable, Identifiable {
        public var id: String { key }
        /// The chart's series key: the server's code, `otherKey` for the folded rest, else the label.
        public let key: String
        /// The server's `group_key`: a category, merchant, account or card code, or a bank code.
        public let code: String?
        public let label: String
        public let colorToken: String?
        public let isOther: Bool
        /// The group's total and share over the range: the server's (Bank, from `spend_breakdown`).
        public let total: Decimal?
        public let share: Decimal?
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { bucket.iso + "|" + groupKey }
        public let bucket: CalendarDay
        public let groupKey: String
        public let amount: Decimal
        public let txnCount: Int?
    }

    public struct Bucket: Sendable, Hashable, Identifiable {
        /// The bucket's first day, ISO: the chart's x value.
        public var id: String { start.iso }
        public let start: CalendarDay
        public let label: String
        public let title: String
        /// The server's total for the bucket; nil when it has no spend.
        public let total: Decimal?
        public let txnCount: Int?
        /// Each group's non-zero slice, in legend order.
        public let entries: [Entry]
    }

    public static let otherKey = "__other__"

    public let range: TrendsRange
    public let grain: SpendGrain
    public let group: TrendsGroup
    /// Legend order: largest first, the folded rest last.
    public let groups: [Group]
    public let buckets: [Bucket]

    /// From `spend_series`: the ungrouped `totals` (the bucket totals) and, unless the grouping
    /// is Total, the `grouped` rows (folded to the top N + "Other" by the server).
    public init(range: TrendsRange, grain: SpendGrain, group: TrendsGroup, totals: [SpendPoint], grouped: [SpendPoint]) {
        func key(_ p: SpendPoint) -> String {
            if let code = p.groupKey { return code }
            return p.groupLabel == "Other" ? Self.otherKey : "label:" + p.groupLabel
        }
        let rows = group == .total ? [] : grouped
        // The summed amounts only rank the legend (and so the palette); they are never shown.
        var rank: [String: Decimal] = [:]
        var first: [String: SpendPoint] = [:]
        for p in rows {
            rank[key(p), default: 0] += p.amount
            if first[key(p)] == nil { first[key(p)] = p }
        }
        let ordered = first.values.sorted { a, b in
            let (ka, kb) = (key(a), key(b))
            if (ka == Self.otherKey) != (kb == Self.otherKey) { return kb == Self.otherKey }
            if rank[ka]! != rank[kb]! { return rank[ka]! > rank[kb]! }
            return (a.groupLabel, ka) < (b.groupLabel, kb)
        }
        var paletteIndex = 0
        groups = ordered.map { p in
            let k = key(p)
            let isOther = k == Self.otherKey
            let token: String?
            if isOther {
                token = SpendBreakdown.otherToken
            } else if group == .category {
                token = p.colorToken
            } else {
                token = ChartPalette.categoryTokens[paletteIndex % ChartPalette.categoryTokens.count]
                paletteIndex += 1
            }
            return Group(key: k, code: p.groupKey, label: isOther ? "Other" : p.groupLabel, colorToken: token,
                         isOther: isOther, total: nil, share: nil)
        }
        let order = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.key, $0) })
        let totalsByBucket = Dictionary(totals.map { ($0.bucket, $0) }, uniquingKeysWith: { a, _ in a })
        let entriesByBucket = Dictionary(grouping: rows.filter { $0.amount != 0 }, by: \.bucket)
        let starts = Set(range.buckets(grain)).union(totals.map(\.bucket)).union(rows.map(\.bucket)).sorted()
        let withYear = Self.monthsRepeat(starts, grain: grain)
        buckets = starts.map { start in
            let entries = (entriesByBucket[start] ?? [])
                .map { Entry(bucket: start, groupKey: key($0), amount: $0.amount, txnCount: $0.txnCount) }
                .sorted { order[$0.groupKey] ?? .max < order[$1.groupKey] ?? .max }
            let total = totalsByBucket[start]
            return Bucket(start: start, label: grain.axisLabel(start, withYear: withYear), title: grain.title(start),
                          total: total?.amount, txnCount: total?.txnCount, entries: entries)
        }
        self.range = range
        self.grain = grain
        self.group = group
    }

    /// From `spend_breakdown` by bank: months with the server's totals, top banks + Others.
    public init(range: TrendsRange, breakdown b: SpendBreakdown) {
        groups = b.groups.map { g in
            Group(key: g.isOther ? Self.otherKey : g.key, code: g.isOther ? nil : g.key, label: g.label,
                  colorToken: b.colorToken(for: g), isOther: g.isOther, total: g.total, share: g.share)
        }
        let months = b.series.compactMap { m in CalendarDay(iso: m.month + "-01").map { ($0, m) } }
        let withYear = Self.monthsRepeat(months.map(\.0), grain: .month)
        buckets = months.map { start, month in
            let entries = b.groups.compactMap { g -> Entry? in
                guard let amount = month.values[g.key], amount != 0 else { return nil }
                return Entry(bucket: start, groupKey: g.isOther ? Self.otherKey : g.key, amount: amount, txnCount: nil)
            }
            return Bucket(start: start, label: SpendGrain.month.axisLabel(start, withYear: withYear),
                          title: SpendGrain.month.title(start), total: entries.isEmpty ? nil : month.total,
                          txnCount: nil, entries: entries)
        }
        self.range = range
        grain = .month
        group = .bank
    }

    /// Month names repeat when the range spans more than a year: label them `"Oct 25"`.
    private static func monthsRepeat(_ starts: [CalendarDay], grain: SpendGrain) -> Bool {
        guard grain == .month else { return false }
        return Set(starts.map(\.month)).count < starts.count
    }

    /// Nothing was spent in the range (the server returned no rows): the empty state's proof.
    public var isEmpty: Bool { buckets.allSatisfy { $0.total == nil } }

    /// The table: buckets with spend, newest first.
    public var spentBuckets: [Bucket] { buckets.filter { $0.total != nil }.reversed() }

    /// Every stacked segment, buckets oldest first and groups in legend order.
    public var segments: [Entry] { buckets.flatMap(\.entries) }

    public func bucket(id: String?) -> Bucket? {
        guard let id else { return nil }
        return buckets.first { $0.id == id }
    }

    public func group(key: String) -> Group? { groups.first { $0.key == key } }

    /// Whether the chart stacks groups (anything but Total).
    public var isGrouped: Bool { group != .total }

    /// The x labels to print when there are more buckets than fit (`maxLabels`): every Nth,
    /// evenly from the first, as the web's `axisTickInterval`.
    public func axisBucketIDs(maxLabels: Int) -> [String] {
        guard buckets.count > maxLabels, maxLabels > 0 else { return buckets.map(\.id) }
        let step = Int((Double(buckets.count) / Double(maxLabels)).rounded(.up))
        return stride(from: 0, to: buckets.count, by: step).map { buckets[$0].id }
    }

    /// `"6 transactions"`.
    public static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 transaction" : "\(count) transactions"
    }
}

extension TrendsSeries {
    /// Activity on the transactions behind a bucket (or one group's slice of it), as the web's
    /// links into `/activity`: the bucket's days within the range, the group, and the filter.
    /// Nil when Activity can't show exactly those (a bank, the folded "Other", several codes of
    /// one kind, or a merchant slice under a search filter).
    public func activityQuery(bucket: Bucket, group slice: Group?) -> ActivityQuery? {
        activityQuery(bucket: bucket, group: slice, filter: filter)
    }

    /// `activityQuery(bucket:group:)` under an explicit filter.
    public func activityQuery(bucket: Bucket, group slice: Group?, filter: SpendFilter) -> ActivityQuery? {
        var query = ActivityQuery()
        query.setRange(from: max(bucket.start, range.from),
                       to: min(grain.bucketEnd(startingAt: bucket.start), range.to))
        var groupSetsCategory = false
        if let slice {
            guard !slice.isOther else { return nil }
            switch group {
            case .total, .bank: return nil
            case .category:
                groupSetsCategory = true
                if let code = slice.code { query.categoryCode = code } else { query.uncategorizedOnly = true }
            case .merchant:
                guard slice.code != nil else { return nil }
                query.search = String(slice.label.prefix(120))
            case .account:
                guard let code = slice.code else { return nil }
                query.accountCode = code
            case .card:
                guard let code = slice.code else { return nil }
                query.cardCode = code
            }
        }
        guard filter.bankCodes.isEmpty, filter.categoryCodes.count <= 1, filter.cardCodes.count <= 1 else { return nil }
        if !groupSetsCategory, let code = filter.categoryCodes.first {
            if code == SpendFilter.uncategorized { query.uncategorizedOnly = true } else { query.categoryCode = code }
        }
        if query.cardCode == nil, let card = filter.cardCodes.first { query.cardCode = card }
        let search = filter.trimmedSearch
        if !search.isEmpty {
            guard query.search.isEmpty else { return nil }
            query.search = String(search.prefix(120))
        }
        return query
    }

    /// The chart for VoiceOver: one series per group (or the totals), from server figures.
    public var accessibility: ChartAccessibility {
        let peak = buckets.filter { $0.total != nil }.max { $0.total! < $1.total! }
        let summary = peak.map { "Highest \(grain.label.lowercased()): \($0.title), \(MoneyFormat.aed($0.total!, fractionDigits: 0))." }
            ?? "No spending in this range."
        let series: [ChartAccessibility.Series]
        if isGrouped {
            series = groups.map { g in
                ChartAccessibility.Series(name: g.label, values: buckets.map { b in
                    b.entries.first { $0.groupKey == g.key }?.amount.chartValue ?? 0
                })
            }
        } else {
            series = [.init(name: "Spend", values: buckets.map { $0.total?.chartValue ?? 0 })]
        }
        let title = isGrouped ? "Spending by \(group.label.lowercased())" : "Spending over time"
        return ChartAccessibility(title: title, summary: summary, xTitle: grain.label,
                                  categories: buckets.map(\.title), yTitle: "AED", series: series)
    }
}

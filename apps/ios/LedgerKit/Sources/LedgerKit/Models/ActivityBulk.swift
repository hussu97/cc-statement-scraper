import Foundation
import Supabase

/// What an Activity bulk action acts on (PAR-11, the web's WEB-24 `TxnSelection`): the ticked
/// rows, or every row matching the filters ("Select all N"). The bulk RPCs take exactly one of
/// `p_txn_codes` and `p_filter`, so a forgotten argument can never mean "everything".
public enum ActivityBulkSelection: Sendable, Hashable {
    /// Ticked rows, sorted so the same rows are the same selection.
    case codes([String])
    /// Every transaction `query` lists, search included (`query.activityFilter`).
    case matching(ActivityQuery)

    public static func ticked(_ codes: some Sequence<String>) -> ActivityBulkSelection {
        .codes(Set(codes).sorted())
    }

    /// The selection half of `activity_selection_summary` / `bulk_update_transactions`' arguments.
    public func params(profileCode: String) -> [String: AnyJSON] {
        var out: [String: AnyJSON] = ["p_profile_code": .string(profileCode)]
        switch self {
        case .codes(let codes): out["p_txn_codes"] = .array(codes.map(AnyJSON.string))
        case .matching(let query): out["p_filter"] = .object(query.activityFilter.mapValues(AnyJSON.string))
        }
        return out
    }

    public var isAllMatching: Bool { if case .matching = self { true } else { false } }
}

/// `rpc('activity_selection_summary')`: the bulk bar's figures, computed on the server over the
/// same rows the list shows (CLAUDE.md §2.2). `net_aed` is a decimal string.
public struct ActivitySelectionSummary: Decodable, Sendable, Hashable {
    public let txnCount: Int
    /// Debits minus credits in AED, pending and posted only.
    public let netAed: Decimal
    /// Pending or posted rows without an AED amount (not in `netAed`).
    public let unpricedCount: Int
    /// Some AED amount in `netAed` is an FX estimate.
    public let hasEstimate: Bool
    /// Rows already excluded from spend: when it is every row, the action is "Include".
    public let excludedCount: Int

    public init(txnCount: Int, netAed: Decimal, unpricedCount: Int = 0, hasEstimate: Bool = false, excludedCount: Int = 0) {
        self.txnCount = txnCount
        self.netAed = netAed
        self.unpricedCount = unpricedCount
        self.hasEstimate = hasEstimate
        self.excludedCount = excludedCount
    }

    /// Every selected row is already excluded, so the bar offers "Include".
    public var allExcluded: Bool { txnCount > 0 && excludedCount == txnCount }

    /// `"AED 1,234.50 net"`, `"+ ≈ AED 20.00 net"`: the server's figure, worded like the Activity header.
    public var netText: String {
        ActivitySummaryHeader(ActivitySummary(txnCount: txnCount, netAed: netAed, unpricedCount: unpricedCount,
                                              hasEstimate: hasEstimate)).netText + " net"
    }
}

/// A bulk write (`bulk_update_transactions.p_patch`): the user fields a client may already set
/// per row (CLAUDE.md §1.10). The web's bulk picker sets a category; it never clears one.
public enum ActivityBulkPatch: Sendable, Hashable {
    case excludeFromSpend(Bool)
    case category(String)

    public var json: AnyJSON {
        switch self {
        case .excludeFromSpend(let excluded): .object(["exclude_from_spend": .bool(excluded)])
        case .category(let code): .object(["manual_category_code": .string(code)])
        }
    }

    /// The web bulk bar's words for a finished action: `"3 transactions categorised"`,
    /// `"1 transaction excluded from spending"`, `"Nothing to change"`.
    public func doneMessage(changed n: Int) -> String {
        guard n > 0 else { return "Nothing to change" }
        let rows = ActivityBulkPatch.count(n, "transaction", "transactions")
        switch self {
        case .category: return "\(rows) categorised"
        case .excludeFromSpend(true): return "\(rows) excluded from spending"
        case .excludeFromSpend(false): return "\(rows) included in spending"
        }
    }

    /// The failure's title, as the web's toast says it.
    public var failureTitle: String {
        switch self {
        case .category: "Couldn't categorise"
        case .excludeFromSpend(true): "Couldn't exclude"
        case .excludeFromSpend(false): "Couldn't include"
        }
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(MoneyFormat.grouped(Decimal(n), fractionDigits: 0)) \(n == 1 ? one : many)"
    }
}

import Foundation
import Observation

/// Statement detail: header, summary tiles, recon explained, and the debit and
/// credit lines. Tapping a line with a transaction opens the transaction sheet.
@MainActor
@Observable
public final class StatementDetailModel {
    public struct Content: Sendable {
        public let detail: StatementDetail
        /// `category_code` → category, for each line's dot and name.
        public let categories: [String: FilterMeta.CategoryOption]
        /// What the transaction sheet offers.
        public let assignable: [FilterMeta.CategoryOption]
    }

    public let stmtCode: String
    /// The account's newest statement: only then can a past due date matter.
    public let isLatest: Bool
    public private(set) var state: LoadState<Content> = .idle
    /// The transaction behind the tapped line, for the sheet.
    public var selected: LedgerTransaction?
    /// The line whose transaction is being fetched.
    public private(set) var opening: String?
    public var errorMessage: String?
    private let api: any LedgerAPI

    public init(api: any LedgerAPI, stmtCode: String, isLatest: Bool = false) {
        self.api = api
        self.stmtCode = stmtCode
        self.isLatest = isLatest
    }

    public func load(profileCode: String) async {
        state = state.startLoading()
        do {
            async let detail = api.statementDetail(profileCode: profileCode, stmtCode: stmtCode)
            async let meta = try? api.filterMeta(profileCode: profileCode)
            let (d, m) = try await (detail, meta)
            let categories = m?.categories ?? []
            state = .loaded(Content(detail: d,
                                    categories: Dictionary(categories.map { ($0.categoryCode, $0) }, uniquingKeysWith: { a, _ in a }),
                                    assignable: m?.assignableCategories ?? []))
        } catch {
            state = .failed(Self.message(for: error), previous: state.value)
        }
    }

    /// Fetches the line's transaction and presents the sheet.
    public func open(_ line: StatementDetail.Line, profileCode: String) async {
        guard let txnCode = line.txnCode, opening == nil else { return }
        opening = line.lineCode
        defer { opening = nil }
        do {
            if let txn = try await api.transactions(profileCode: profileCode, codes: [txnCode]).first {
                selected = txn
            } else {
                errorMessage = "This line's transaction is no longer in this ledger. Pull to refresh."
            }
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
        }
    }

    public func setCategory(_ txn: LedgerTransaction, to categoryCode: String, applyToMerchant: Bool,
                            profileCode: String) async -> Bool {
        do {
            try await api.setTransactionCategory(txnCode: txn.txnCode, categoryCode: categoryCode,
                                                 applyToMerchant: applyToMerchant && txn.merchantCode != nil)
            await load(profileCode: profileCode)
            return true
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
            return false
        }
    }

    /// P0002: the statement was superseded or removed since the list loaded.
    nonisolated static func message(for error: any Error) -> String {
        if case .server(_, "P0002", _)? = error as? LedgerAPIError {
            return "This statement is no longer in this ledger. It may have been replaced by a newer upload."
        }
        return LoadState<Int>.message(for: error)
    }
}

// MARK: - Presentation

/// A figure in the summary grid. `value` is nil when the PDF didn't print it.
public struct SummaryTile: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public let title: String
    public let value: String
    public let tone: Tone
}

/// One reconciliation check, in a sentence.
public struct ReconFinding: Sendable, Hashable, Identifiable {
    public var id: String { text }
    public let text: String
    public let tone: Tone
    /// `true` passed, `false` failed, nil informational.
    public let passed: Bool?
}

public enum ReconPresentation {
    /// The status chip: `ok` → Reconciled, … (also the first chip on a cycle row).
    public static func status(_ status: String?) -> (label: String, tone: Tone) {
        switch status {
        case "ok": ("Reconciled", .positive)
        case "warn": ("Check", .warn)
        case "fail": ("Mismatch", .danger)
        // A history extract has no totals: nothing to reconcile (DP-08). Neutral, not an error.
        case "n/a": ("Nothing to reconcile", .neutral)
        default: ("Not reconciled", .neutral)
        }
    }

    /// Every check the server ran, as a sentence. Figures are the server's
    /// (`sum_debits`, `expected_closing`) beside the statement's own totals.
    public static func findings(status: String?, checks: ReconChecks?, header: StatementDetail.Header) -> [ReconFinding] {
        var out: [ReconFinding] = []
        switch status {
        case "n/a":
            out.append(.init(text: "A history extract has no totals, so there is nothing to check its lines against.", tone: .neutral, passed: nil))
        case nil:
            out.append(.init(text: "Not reconciled yet. Checks run after the statement is imported.", tone: .neutral, passed: nil))
        default: break
        }
        guard let checks else { return out }
        func aed(_ v: Decimal?) -> String { v.map { MoneyFormat.aed($0) } ?? "—" }
        if checks.totals == "not_extracted" {
            out.append(.init(text: "The statement's totals couldn't be read, so its lines can't be checked against them.", tone: .warn, passed: nil))
        }
        if let ok = checks.debitsMatch {
            out.append(ok
                ? .init(text: "Debit lines add up to the statement's total debits (\(aed(header.totalDebits))).", tone: .positive, passed: true)
                : .init(text: "Debit lines add up to \(aed(checks.sumDebits)), but the statement says \(aed(header.totalDebits)).", tone: .danger, passed: false))
        }
        if let ok = checks.creditsMatch {
            out.append(ok
                ? .init(text: "Credit lines add up to the statement's total credits (\(aed(header.totalCredits))).", tone: .positive, passed: true)
                : .init(text: "Credit lines add up to \(aed(checks.sumCredits)), but the statement says \(aed(header.totalCredits)).", tone: .danger, passed: false))
        }
        if let ok = checks.balanceEquation {
            out.append(ok
                ? .init(text: "Opening balance + debits − credits = closing balance.", tone: .positive, passed: true)
                : .init(text: "Opening balance + debits − credits gives \(aed(checks.expectedClosing)), not the closing balance of \(aed(header.closingBalance)).", tone: .danger, passed: false))
        }
        if checks.noLines == true {
            out.append(.init(text: "No lines were read from this statement although it shows activity.", tone: .warn, passed: false))
        }
        if let n = checks.unpricedLines, n > 0 {
            out.append(.init(text: "\(plural(n, "line is", "lines are")) waiting for an AED amount (foreign currency), so the sums are approximate.", tone: .info, passed: nil))
        }
        if let n = checks.heldLines, n > 0 {
            out.append(.init(text: "\(plural(n, "line is", "lines are")) waiting in Review.", tone: .warn, passed: nil))
        }
        if let n = checks.unmatchedSms, n > 0 {
            out.append(.init(text: "\(plural(n, "SMS alert", "SMS alerts")) from this period \(n == 1 ? "isn't" : "aren't") on the statement.", tone: .warn, passed: nil))
        }
        if let coverage = checks.smsCoverage {
            out.append(.init(text: "\(MoneyFormat.percent(coverage)) of lines were also seen by SMS.", tone: .info, passed: nil))
        }
        return out
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}

extension StatementDetail.Header {
    public var kindLabel: String { kind == "history_extract" ? "History extract" : "Statement" }

    /// `"•1234 · •5678"`, nil when no card is known.
    public var cardsLabel: String? {
        cardLast4s.isEmpty ? nil : cardLast4s.map { "•\($0)" }.joined(separator: " · ")
    }

    /// `"26 Aug – 25 Sep 2026"`.
    public var periodLabel: String? {
        guard let start = periodStart, let end = periodEnd else { return nil }
        return "\(LedgerDates.dayLabel(start, today: end)) – \(LedgerDates.fullDayLabel(end))"
    }

    /// Opening, debits, credits, closing, minimum due, limit; "—" when not printed.
    public var tiles: [SummaryTile] {
        func tile(_ title: String, _ v: Decimal?, _ tone: Tone = .neutral) -> SummaryTile {
            SummaryTile(title: title, value: v.map { MoneyFormat.aed($0) } ?? "—", tone: tone)
        }
        var tiles = [
            tile("Opening balance", openingBalance),
            tile("Total debits", totalDebits),
            tile("Total credits", totalCredits, .positive),
            tile("Closing balance", closingBalance),
            tile("Minimum due", minDue),
        ]
        if creditLimit != nil { tiles.append(tile("Credit limit", creditLimit)) }
        return tiles
    }

    public func due(isLatest: Bool, today: CalendarDay = LedgerDates.today()) -> (text: String, tone: Tone)? {
        DueStatus.describe(due: dueDate, isLatest: isLatest, today: today)
    }
}

extension StatementDetail.Line {
    /// The merchant when the line is linked, else the printed text.
    public var title: String {
        if let merchantName, !merchantName.isEmpty { return merchantName }
        return description.isEmpty ? "Statement line" : description
    }

    /// The printed text under a merchant name, when it says something else.
    public var printedDetail: String? {
        guard let merchantName, !merchantName.isEmpty, !description.isEmpty,
              description.caseInsensitiveCompare(merchantName) != .orderedSame else { return nil }
        return description
    }

    public var dateLabel: String { LedgerDates.dayLabel(txnDate) }

    /// `"AED 45.00"` for a debit, `"+ AED 120.00"` for a credit; the original
    /// amount when the AED figure isn't known yet.
    public func amountLabel(isCredit: Bool) -> String {
        let sign = isCredit ? "+ " : ""
        if let amountAed { return sign + MoneyFormat.aed(amountAed) }
        if let amountOriginal, let currencyOriginal { return sign + "≈ " + MoneyFormat.amount(amountOriginal, currency: currencyOriginal) }
        return "—"
    }

    /// `"USD 12.34"` for a foreign-currency line.
    public var originalLabel: String? {
        guard let amountOriginal, let currencyOriginal, currencyOriginal.uppercased() != "AED", amountAed != nil else { return nil }
        return MoneyFormat.amount(amountOriginal, currency: currencyOriginal)
    }

    /// A chip for anything that isn't an ordinary purchase.
    public var kindLabel: String? {
        switch kind {
        case nil, "purchase": nil
        case "cash_advance": "Cash advance"
        case let k?: k.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var canOpen: Bool { txnCode != nil }

    /// One VoiceOver sentence for the row.
    public func accessibilityLabel(isCredit: Bool, categoryName: String?) -> String {
        var parts = [title, dateLabel, amountLabel(isCredit: isCredit)]
        if let originalLabel { parts.append("originally \(originalLabel)") }
        if let kindLabel { parts.append(kindLabel) }
        parts.append(categoryName ?? (txnCode == nil ? "not matched to a transaction" : "uncategorised"))
        return parts.joined(separator: ", ")
    }
}

extension StatementDetail.Side {
    /// `"12 · AED 4,210.55"`.
    public var summary: String { "\(count) · \(MoneyFormat.aed(total))" }
}

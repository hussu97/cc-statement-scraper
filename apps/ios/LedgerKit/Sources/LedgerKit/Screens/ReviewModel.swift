import Foundation
import Observation

/// One review as the Review screen lists it: what it is about and what the
/// user can do (only what `resolve_review` accepts for it).
public struct ReviewItem: Sendable, Hashable, Identifiable {
    public var id: String { review.reviewCode }
    public let review: MatchReview
    /// `"ADCB •9208 · AED 46.00 · VOX CINEMAS"`.
    public let subject: String
    /// `"Received 9 Aug"` / `"On statement 9 Aug"`.
    public let subjectDetail: String?
    public let options: [Option]
    /// Shown when the phone offers only "Dismiss" for this kind of review.
    public let note: String?

    public struct Option: Sendable, Hashable, Identifiable {
        public var id: String { label }
        public let label: String
        public let action: ReviewAction
        public var isDestructive: Bool { action == .dismiss }
    }
}

public struct ReviewGroup: Sendable, Hashable, Identifiable {
    public var id: String { reason }
    public let reason: String
    public let title: String
    public let help: String
    public let items: [ReviewItem]
}

/// The wording and the allowed actions, as pure functions (the web's
/// `REVIEW_REASONS` / `REASON_ORDER` in `apps/web/src/data/reviews.ts`).
public enum ReviewPresentation {
    public static let order = ["unknown_card", "ambiguous", "low_score", "amount_drift", "unparsed_sms",
                               "period_overlap", "missing_from_statement", "orphaned"]

    public static func title(_ reason: String) -> String {
        switch reason {
        case "ambiguous": "Ambiguous matches"
        case "low_score": "Weak matches"
        case "amount_drift": "Amount changed"
        case "unknown_card": "Unknown cards"
        case "unparsed_sms": "New SMS formats"
        case "orphaned": "Orphaned transactions"
        case "missing_from_statement": "Missing from statement"
        case "period_overlap": "Overlapping statements"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public static func help(_ reason: String) -> String {
        switch reason {
        case "ambiguous": "More than one transaction fits. Pick the right one, or keep it as a new transaction."
        case "low_score": "The closest transaction is only a partial match. Link it if it's the same purchase."
        case "amount_drift": "The posted amount differs from the alert."
        case "unknown_card": "An SMS mentions a card Ledger doesn't know. Choose the account it belongs to; waiting messages from it are then processed."
        case "unparsed_sms": "A bank message didn't match any format. Review the proposed template on the web."
        case "orphaned": "Their only evidence was removed. Dismiss once checked."
        case "missing_from_statement": "An SMS purchase never appeared on its statement. It may have been released."
        case "period_overlap": "Two statements of the same card cover the same days. Resolve it on the web."
        default: ""
        }
    }

    public static func groups(_ inbox: ReviewInbox) -> [ReviewGroup] {
        let byReason = Dictionary(grouping: inbox.reviews, by: \.reason)
        func rank(_ r: String) -> Int { order.firstIndex(of: r) ?? order.count }
        return byReason.keys.sorted { (rank($0), $0) < (rank($1), $1) }.map { reason in
            ReviewGroup(reason: reason, title: title(reason), help: help(reason),
                        items: byReason[reason]!.map { item($0, inbox: inbox) })
        }
    }

    public static func item(_ review: MatchReview, inbox: ReviewInbox) -> ReviewItem {
        let (subject, detail) = describeSubject(review, inbox: inbox)
        var options: [ReviewItem.Option] = []
        var note: String?
        let canMatch = review.subjectType == "sms" || review.subjectType == "statement_line"

        switch review.reason {
        case "unknown_card":
            let bank = inbox.sms[review.subjectCode]?.bankCode ?? review.candidates.first?.bankCode
            let last4 = inbox.sms[review.subjectCode]?.cardLast4 ?? review.candidates.first?.last4
            let accounts = inbox.accounts.filter { bank == nil || $0.bankCode == bank }
            let card = last4.map { "•\($0)" } ?? "this card"
            options = accounts.map {
                .init(label: "Add \(card) to \($0.title)", action: .registerCard(accountCode: $0.accountCode))
            }
            if accounts.isEmpty {
                note = "No \(bank ?? "matching") account yet. It appears after a statement from that bank; or add it on the web."
            }
        case "ambiguous", "low_score", "amount_drift":
            guard canMatch else {
                note = "More options for this are on the web."
                break
            }
            for code in review.candidates.compactMap(\.txnCode) {
                guard let txn = inbox.transactions[code] else { continue }
                let day = LedgerDates.dayLabel(txn.txnDate)
                options.append(.init(label: "Same as \(txn.title) · \(txn.amountLabel) · \(day)", action: .link(txnCode: code)))
            }
            options.append(.init(label: "Keep as a new transaction", action: .createNew))
        default:
            note = "More options for this are on the web."
        }
        options.append(.init(label: "Dismiss", action: .dismiss))
        return ReviewItem(review: review, subject: subject, subjectDetail: detail, options: options, note: note)
    }

    static func describeSubject(_ review: MatchReview, inbox: ReviewInbox) -> (String, String?) {
        if let sms = inbox.sms[review.subjectCode] {
            var parts: [String] = []
            let card = [sms.bankCode, sms.cardLast4.map { "•\($0)" }].compactMap { $0 }.joined(separator: " ")
            if !card.isEmpty { parts.append(card) }
            if let amount = sms.amount { parts.append(MoneyFormat.amount(amount, currency: sms.currency ?? "AED")) }
            if let merchant = sms.merchantRaw, !merchant.isEmpty { parts.append(merchant) }
            return (parts.isEmpty ? "Bank SMS" : parts.joined(separator: " · "),
                    "SMS received \(LedgerDates.dayLabel(CalendarDay(date: sms.receivedAt)))")
        }
        if let line = inbox.lines[review.subjectCode] {
            let sign = line.direction == "credit" ? "+ " : ""
            let amount = sign + MoneyFormat.amount(line.amountOriginal, currency: line.currencyOriginal)
            return ("\(line.description) · \(amount)", "Statement line, \(LedgerDates.dayLabel(line.txnDate))")
        }
        if let txn = inbox.transactions[review.subjectCode] {
            return ("\(txn.title) · \(txn.amountLabel)", "Transaction, \(LedgerDates.dayLabel(txn.txnDate))")
        }
        if let candidate = review.candidates.first, let bank = candidate.bankCode {
            return ([bank, candidate.last4.map { "•\($0)" }].compactMap { $0 }.joined(separator: " "), nil)
        }
        return (title(review.reason), nil)
    }

    /// What the server did, in words.
    public static func outcomeMessage(_ outcome: String) -> String {
        switch outcome {
        case "card_registered": "Card added. Waiting messages from it are being processed."
        case "linked": "Linked."
        case "created": "Kept as a new transaction."
        case "dismissed": "Dismissed."
        default: "Done."
        }
    }
}

/// The Review screen: open `match_reviews` for the active ledger.
@MainActor
@Observable
public final class ReviewModel {
    public private(set) var state: LoadState<[ReviewGroup]> = .idle
    public private(set) var working: String?
    public var message: String?
    private let api: any LedgerAPI

    public init(api: any LedgerAPI) { self.api = api }

    public var isEmpty: Bool { state.value?.isEmpty ?? false }

    public func load(profileCode: String) async {
        state = state.startLoading()
        do {
            state = .loaded(ReviewPresentation.groups(try await api.reviewInbox(profileCode: profileCode)))
        } catch {
            state = state.fail(error)
        }
    }

    public func resolve(_ item: ReviewItem, _ option: ReviewItem.Option, profileCode: String) async {
        working = item.id
        defer { working = nil }
        do {
            let outcome = try await api.resolveReview(reviewCode: item.review.reviewCode, action: option.action)
            message = ReviewPresentation.outcomeMessage(outcome)
        } catch {
            message = LoadState<Int>.message(for: error)
        }
        await load(profileCode: profileCode)
    }
}

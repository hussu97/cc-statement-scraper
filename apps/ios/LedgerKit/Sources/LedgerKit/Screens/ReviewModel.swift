import Foundation
import Observation

/// One review as the Review screen lists it: what it is about and what the
/// user can do (only what `resolve_review` accepts for it).
public struct ReviewItem: Sendable, Hashable, Identifiable {
    public var id: String { review.reviewCode }
    public let review: MatchReview
    /// `"ADCB •3687 · AED 46.00 · VOX CINEMAS"`.
    public let subject: String
    /// `"Received 9 Aug"` / `"On statement 9 Aug"`.
    public let subjectDetail: String?
    public let options: [Option]
    /// Shown when the phone offers only "Dismiss" for this kind of review.
    public let note: String?
    /// The bank the subject belongs to, drawn as its logo beside `subjectBody`.
    public var bankCode: String? = nil

    /// `subject` without the leading bank code the logo replaces:
    /// `"•3687 · AED 46.00 · VOX CINEMAS"`. VoiceOver reads the logo's bank name first.
    public var subjectBody: String {
        guard let bankCode, subject.hasPrefix(bankCode) else { return subject }
        let rest = subject.dropFirst(bankCode.count).drop { $0 == " " }
        return rest.isEmpty ? subject : String(rest)
    }

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
        case "unparsed_sms": "A bank message didn't match any format. Ask the AI to try again, or mark it as not a card transaction. Proposed formats are accepted on the web."
        case "orphaned": "Their only evidence was removed, so they count in no total. Void them once checked."
        case "missing_from_statement": "An SMS purchase never appeared on its statement. It may have been released."
        case "period_overlap": "Two statements of the same card cover the same days. Resolve it on the web."
        default: ""
        }
    }

    public static func groups(_ inbox: ReviewInbox) -> [ReviewGroup] {
        groups(items(inbox))
    }

    /// Every review of a page, described with that page's inbox.
    public static func items(_ inbox: ReviewInbox) -> [ReviewItem] {
        inbox.reviews.map { item($0, inbox: inbox) }
    }

    /// Items (from any number of pages) grouped by reason, in `order`;
    /// newest first within a group, as loaded.
    public static func groups(_ items: [ReviewItem]) -> [ReviewGroup] {
        let byReason = Dictionary(grouping: items, by: \.review.reason)
        func rank(_ r: String) -> Int { order.firstIndex(of: r) ?? order.count }
        return byReason.keys.sorted { (rank($0), $0) < (rank($1), $1) }.map { reason in
            ReviewGroup(reason: reason, title: title(reason), help: help(reason), items: byReason[reason]!)
        }
    }

    public static func item(_ review: MatchReview, inbox: ReviewInbox) -> ReviewItem {
        let (subject, detail) = describeSubject(review, inbox: inbox)
        var options: [ReviewItem.Option] = []
        var note: String?
        var dismissLabel = "Dismiss"
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
            if review.subjectType == "sms" {
                options.append(.init(label: "Not a card transaction", action: .notATransaction))
            }
        case "unparsed_sms" where review.subjectType == "sms":
            // Same as the web's footer: without a proposed format, the AI can
            // try again; a proposal is accepted or rejected on the web.
            if review.candidates.contains(where: { $0.templateCode != nil }) {
                note = "Ledger proposed a format for this message. Accept or reject it on the web."
            } else {
                options.append(.init(label: "Retry with AI", action: .retryWithAI))
            }
            options.append(.init(label: "Not a card transaction", action: .notATransaction))
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
        case "orphaned" where review.subjectType == "transaction":
            // resolve_review voids the transaction when its orphan review is dismissed.
            dismissLabel = "Void transaction"
        default:
            note = "More options for this are on the web."
        }
        options.append(.init(label: dismissLabel, action: .dismiss))
        let bank = inbox.sms[review.subjectCode]?.bankCode
            ?? (inbox.lines[review.subjectCode] == nil && inbox.transactions[review.subjectCode] == nil
                ? review.candidates.first?.bankCode : nil)
        return ReviewItem(review: review, subject: subject, subjectDetail: detail, options: options, note: note,
                          bankCode: bank)
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
        case "ignored": "Marked as not a card transaction."
        case "superseded": "Older statement superseded."
        case "retrying": "Sent to the AI again. If it still can't read the message, it comes back here."
        default: "Done."
        }
    }

    /// `resolve_review` / `retry_sms_fallback` errors in words (the web's
    /// `reviewActionError`). P0002: the review, or a code in the answer, is gone
    /// or belongs to another ledger — usually it was answered elsewhere. 22023:
    /// the answer doesn't fit the review (e.g. a transaction on another account).
    public static func errorMessage(_ error: any Error) -> String {
        guard case let .server(_, code, message)? = error as? LedgerAPIError else {
            return LoadState<Int>.message(for: error)
        }
        func has(_ needle: String) -> Bool { message.range(of: needle, options: .caseInsensitive) != nil }
        switch code {
        case "P0002":
            return has("is not open")
                ? "This review was already answered, or it's no longer in this ledger. The list has been refreshed."
                : "Something this answer refers to no longer exists in this ledger. The list has been refreshed."
        case "22023":
            if has("different account") || has("not on this message's account") {
                return "That transaction is on a different card account, so it can't be linked here."
            }
            if has("already part of a transaction") {
                return "This message is already part of a transaction, so it can't be marked as not a card transaction."
            }
            if has("already has a confirmed") {
                return "That transaction already has its own statement line or SMS, so it can't take this one."
            }
            if has("not an open unparsed_sms review") {
                return "Only an open unrecognised-SMS review can be sent to the AI again."
            }
            if has("no account or amount") {
                return "Ledger doesn't know this message's card or amount yet. Add the card first."
            }
            return "That answer doesn't fit this review. The list has been refreshed."
        default:
            return LoadState<Int>.message(for: error)
        }
    }
}

/// The Review screen: open `match_reviews` for the active ledger.
@MainActor
@Observable
public final class ReviewModel {
    /// Open reviews, newest first, page after page.
    public let list = Paginator<ReviewItem>()
    public private(set) var working: String?
    public var message: String?
    private let api: any LedgerAPI
    private var loadedProfile: String?

    public init(api: any LedgerAPI) { self.api = api }

    /// The loaded reviews, grouped by reason.
    public var state: LoadState<[ReviewGroup]> {
        switch list.state {
        case .idle: .idle
        case .loading(let items): .loading(previous: items.map(ReviewPresentation.groups))
        case .loaded(let items): .loaded(ReviewPresentation.groups(items))
        case .failed(let message, let items): .failed(message, previous: items.map(ReviewPresentation.groups))
        }
    }

    public var footer: ListFooter { list.footer }
    public var isEmpty: Bool { list.state.value?.isEmpty ?? false }
    public var hasLoaded: Bool { loadedProfile != nil }

    /// `"All 140 reviews"` under the last group.
    public var endMessage: String {
        ListEnd.message(count: list.items.count, total: list.total, singular: "review", plural: "reviews")
    }

    public func load(profileCode: String) async {
        let same = loadedProfile == profileCode
        loadedProfile = profileCode
        let api = self.api
        await list.reload(keepingRows: same) { page in
            let inbox = try await api.reviewInbox(profileCode: profileCode, page: page)
            return ListPage(items: ReviewPresentation.items(inbox), total: inbox.total)
        }
    }

    /// Opening the screen: a fresh read (answers may have come from the web),
    /// keeping the rows already shown for this ledger while it loads.
    public func open(profileCode: String) async {
        if loadedProfile == profileCode, list.hasLoaded { await list.refreshHead() } else { await load(profileCode: profileCode) }
    }

    public func footerAppeared() async { await list.footerAppeared() }
    public func loadMore() async { await list.loadMore() }

    /// Realtime / foreground, when the screen has been opened for this ledger.
    public func refresh(profileCode: String) async {
        guard loadedProfile == profileCode else { return }
        await list.refreshHead()
    }

    public func reset() {
        list.reset()
        loadedProfile = nil
        working = nil
        message = nil
    }

    public func resolve(_ item: ReviewItem, _ option: ReviewItem.Option, profileCode: String) async {
        working = item.id
        defer { working = nil }
        do {
            let outcome = try await api.resolveReview(reviewCode: item.review.reviewCode, action: option.action)
            message = ReviewPresentation.outcomeMessage(outcome)
            list.remove([item.id])   // answered: gone at once, wherever the reader has scrolled to
        } catch {
            message = ReviewPresentation.errorMessage(error)
        }
        // An answer can close other reviews too (a registered card frees its
        // waiting messages): refresh the newest page, keep the scrolled ones.
        if loadedProfile == profileCode { await list.refreshHead() } else { await load(profileCode: profileCode) }
    }
}

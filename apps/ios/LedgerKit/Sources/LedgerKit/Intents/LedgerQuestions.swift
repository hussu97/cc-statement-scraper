import Foundation

/// The answers behind the App Intents beyond SMS (BACKLOG N-3): "How much have
/// I spent this month?", "What's due?" and "Categorise last transaction". The
/// intents in `Ledger/Intents` are plumbing; every word and every choice is here.
///
/// They answer for the ledger on screen in the app (`ProfileSelection`), ask the
/// server first (`rpc('overview')`, the same figures as Overview), and fall back
/// to the widgets' snapshot when the server can't be reached, saying how old it is.
public struct LedgerQuestions: Sendable {
    let api: any LedgerAPI
    let profileCode: @Sendable () -> String?
    let snapshot: @Sendable () -> WidgetSnapshot?

    public init(api: any LedgerAPI, profileCode: @escaping @Sendable () -> String?,
                snapshot: @escaping @Sendable () -> WidgetSnapshot?) {
        self.api = api
        self.profileCode = profileCode
        self.snapshot = snapshot
    }

    public static let noLedger = "Open Bank Ledger and choose a ledger first."

    /// What an answer was built from.
    public enum Source: Equatable, Sendable {
        case server
        /// The App Group snapshot, written at this time.
        case saved(Date)
        case none
    }

    /// The figures for the ledger on screen: fresh from the server, else the
    /// saved snapshot of the same ledger, else the reason there are none.
    func figures(now: Date) async -> (WidgetSnapshot?, Source, failure: String?) {
        guard let code = profileCode() else { return (nil, .none, Self.noLedger) }
        let saved = snapshot().flatMap { $0.profileCode == code ? $0 : nil }
        do {
            let overview = try await api.overview(profileCode: code, month: nil)
            let fresh = WidgetSnapshot.make(overview: overview, profileCode: code, ledgerName: saved?.ledgerName,
                                            now: now)
            return (fresh, .server, fresh == nil ? "Bank Ledger couldn't load this month." : nil)
        } catch {
            if let saved { return (saved, .saved(saved.generatedAt), nil) }
            return (nil, .none, Self.failure(error))
        }
    }

    static func failure(_ error: any Error) -> String {
        guard let api = error as? LedgerAPIError else { return "Bank Ledger couldn't answer that." }
        switch api.kind {
        case .signedOut: return "You are signed out. Open Bank Ledger to sign in."
        case .transient: return "No connection to Bank Ledger, and nothing is saved on this device yet."
        case .permanent: return api.description
        }
    }

    // MARK: How much have I spent this month?

    /// `"You've spent AED 837 in October so far in Demo ledger, 86% below the same
    /// day last month."` The value is the server's spend as a plain decimal.
    public func monthSpend(now: Date = .now) async -> (value: String?, dialog: String) {
        let (figures, source, failure) = await figures(now: now)
        guard let figures else { return (nil, failure ?? Self.noLedger) }
        let today = LedgerDates.today(now: now)
        guard figures.month.year == today.year, figures.month.month == today.month else {
            return (nil, "Bank Ledger has nothing saved for \(LedgerDates.monthName(today)) yet. Open it to load the month.")
        }
        var line = "You've spent \(MoneyFormat.aed(figures.spend, fractionDigits: 0)) in \(LedgerDates.monthName(today)) so far"
        if let name = figures.ledgerName { line += " in \(name)" }
        if let pace = SpendComparison.versusSameDayLastMonth(
            change: figures.changeVsPrevMonthToDate, spend: figures.spend, previous: figures.spendPrevMonthToDate) {
            line += ", \(Self.lowercasedFirst(pace.text))"
        }
        return (MoneyFormat.plain(figures.spend), Self.prefix(source, today: today) + line + ".")
    }

    // MARK: What's due?

    /// Every statement still to pay, soonest first: `"Everyday: AED 8,285.56 due
    /// today (13 Oct), minimum AED 414.28."` One line per card, at most three.
    public func whatsDue(now: Date = .now) async -> (count: Int, dialog: String) {
        let (figures, source, failure) = await figures(now: now)
        guard let figures else { return (0, failure ?? Self.noLedger) }
        let today = LedgerDates.today(now: now)
        let upcoming = WidgetDue.upcoming(figures.cards, today: today)
        guard !upcoming.isEmpty else {
            let line = switch WidgetDue.whyNothingDue(figures.cards, today: today) {
            case .paid: "Nothing is due: every upcoming statement is paid."
            case .passed: "Nothing is due: every statement's due date has passed."
            case .noStatements: "No statements yet, so nothing is due."
            }
            return (0, Self.prefix(source, today: today) + line)
        }
        let lines = upcoming.prefix(3).map { card -> String in
            let due = card.dueDate!
            // The server's payment status words it: "due in 5 days", "part paid (AED 1,000.00), due in 5 days".
            let status = DueStatus.describe(due: due, isLatest: true, payment: card.duePayment, today: today)
            let when = Self.spoken(status?.text ?? LedgerDates.dueLabel(due, today: today))
            var line = "\(card.title): "
            line += card.closingBalance.map { "\(MoneyFormat.aed($0)) \(when)" } ?? when.capitalizedFirst
            line += " (\(LedgerDates.dayLabel(due, today: today)))"
            if let min = card.minDue { line += ", minimum \(MoneyFormat.aed(min))" }
            return line + "."
        }
        var dialog = Self.prefix(source, today: today) + lines.joined(separator: " ")
        if upcoming.count > 3 { dialog += " And \(upcoming.count - 3) more in Bank Ledger." }
        return (upcoming.count, dialog)
    }

    // MARK: Categorise last transaction

    /// The categories a transaction can be filed under (not archived), for the
    /// intent's `CategoryEntity` picker.
    public func categories() async throws -> [FilterMeta.CategoryOption] {
        guard let code = profileCode() else { throw LedgerAPIError.noProfile }
        return try await api.filterMeta(profileCode: code).assignableCategories
    }

    /// How many recent rows "the last transaction" is looked for in.
    static let lastTransactionWindow = 20

    /// Files the newest purchase of the ledger on screen under `categoryCode`,
    /// for that transaction only (never the merchant's rule). "Last" is
    /// Activity's order (newest first); refunds, payments and fees are skipped,
    /// since what someone categorises after paying is the purchase.
    public func categoriseLast(categoryCode: String, categoryName: String) async -> (txnCode: String?, dialog: String) {
        guard let code = profileCode() else { return (nil, Self.noLedger) }
        do {
            let page = try await api.transactions(profileCode: code, query: ActivityQuery(),
                                                  page: PageRequest(offset: 0, limit: Self.lastTransactionWindow))
            guard let txn = page.rows.first(where: { $0.kind == "purchase" && $0.status != "void" }) else {
                return (nil, "There's no recent purchase to categorise.")
            }
            let what = "\(txn.title) (\(txn.amountLabel), \(LedgerDates.dayLabel(txn.txnDate)))"
            if txn.categoryCode == categoryCode {
                return (txn.txnCode, "\(what) is already under \(categoryName).")
            }
            try await api.setTransactionCategory(txnCode: txn.txnCode, categoryCode: categoryCode, applyToMerchant: false)
            return (txn.txnCode, "Filed \(what) under \(categoryName).")
        } catch {
            return (nil, Self.failure(error))
        }
    }

    // MARK: Words

    /// `"As of 14:05: "` when the answer comes from the saved snapshot.
    static func prefix(_ source: Source, today: CalendarDay) -> String {
        guard case .saved(let at) = source else { return "" }
        let day = CalendarDay(date: at)
        let when = day == today ? LedgerDates.timeLabel(at) : LedgerDates.dayLabel(day, today: today)
        return "Offline, as of \(when): "
    }

    /// `DueStatus` wording inside a sentence: `"Part paid (AED 1,000.00) · Due
    /// in 5 days"` → `"part paid (AED 1,000.00), due in 5 days"`.
    static func spoken(_ status: String) -> String {
        lowercasedFirst(status)
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "Due", with: "due")
    }

    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

extension String {
    /// `"due today"` → `"Due today"`.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

import Foundation

/// Where a widget is drawn.
public enum WidgetPlacement: Sendable, Equatable {
    /// Home Screen (and the Today view): reached only once the device is unlocked.
    case homeScreen
    /// Lock Screen accessories: readable by anyone holding the locked device.
    case lockScreen
}

/// The widgets' kinds (`StaticConfiguration(kind:)`), shared by the extension
/// and the app's reloads.
public enum LedgerWidgetKind {
    public static let spend = "ledger.widget.spend"
    public static let due = "ledger.widget.due"
    public static let utilisation = "ledger.widget.utilisation"
}

/// Whether a widget may draw money.
///
/// Decision (N-2): with Settings → Require Face ID on, the owner has asked for
/// Bank Ledger's figures to stay behind Face ID, so **Lock Screen widgets draw
/// no amounts** (spend, statement balance, minimum due). They still show what
/// is not money: the pace in words, the due date and utilisation as a percent.
/// Home Screen widgets keep their amounts, because the Home Screen is only
/// reachable once the device is unlocked; their amounts are also marked
/// privacy-sensitive so iOS redacts them wherever it draws them while locked
/// (StandBy). With the setting off, every widget shows amounts.
public enum WidgetPrivacy {
    public static func showsAmounts(on placement: WidgetPlacement, requireAuth: Bool) -> Bool {
        placement == .homeScreen || !requireAuth
    }

    /// What stands in for a hidden amount.
    public static let hiddenAmount = "Hidden"
    public static let hiddenFootnote = "Amounts hidden: Require Face ID is on"
}

/// When a widget's timeline runs out: the next Dubai midnight, so "Due in 3
/// days" and the month's name roll over without the app. Everything else
/// changes only when the app writes a new snapshot (and reloads the timelines).
public enum WidgetTimeline {
    public static func nextRefresh(after now: Date) -> Date {
        let today = LedgerDates.today(now: now)
        return today.adding(days: 1).startDate
    }
}

/// Words for the month spend widget.
public struct SpendWidgetContent: Sendable, Equatable {
    /// `"October"`.
    public let monthName: String
    /// `"AED 860"`; nil when hidden or there is no snapshot for this month.
    public let amount: String?
    /// The hero number alone (`"860"`), for the large layouts.
    public let heroNumber: String?
    /// The server's month-to-date comparison: `"18% below the same day last month"`.
    public let pace: String?
    /// `"18% below last month"`: the Lock Screen's and the small widget's width.
    public let paceShort: String?
    public let paceTone: Tone
    /// `"Home · updated 14:05"`; the hidden-amount note on a locked Lock Screen.
    public let footnote: String?
    /// `"Updated 14:05"`: the small widget's footnote.
    public let footnoteShort: String?
    /// Instead of figures: no snapshot yet, or one from an earlier month.
    public let message: String?
    /// One line for `accessoryInline`: `"October AED 860 · 18% below last month"`.
    public let inline: String
    public let accessibilityLabel: String

    public static func make(snapshot: WidgetSnapshot?, placement: WidgetPlacement, requireAuth: Bool,
                            now: Date = .now) -> SpendWidgetContent {
        let today = LedgerDates.today(now: now)
        let monthName = LedgerDates.monthName(today)
        guard let snapshot else {
            return .message("Open Bank Ledger to see this month's spend.", monthName: monthName)
        }
        guard snapshot.month.year == today.year, snapshot.month.month == today.month else {
            return .message("Open Bank Ledger to load \(monthName).", monthName: monthName)
        }
        let showsAmounts = WidgetPrivacy.showsAmounts(on: placement, requireAuth: requireAuth)
        let comparison = SpendComparison.versusSameDayLastMonth(
            change: snapshot.changeVsPrevMonthToDate, spend: snapshot.spend, previous: snapshot.spendPrevMonthToDate)
        let short = comparison.map { Self.shorten($0.text) }
        let amount = showsAmounts ? MoneyFormat.aed(snapshot.spend, fractionDigits: 0) : nil
        let footnote = showsAmounts
            ? WidgetFootnote.updated(snapshot, today: today)
            : WidgetPrivacy.hiddenFootnote
        let footnoteShort = showsAmounts ? WidgetFootnote.updated(snapshot, today: today, withLedger: false) : nil
        let inline = [monthName + (amount.map { " \($0)" } ?? ""), short].compactMap { $0 }.joined(separator: " · ")
        var spoken = showsAmounts ? "\(monthName) spend so far, \(MoneyFormat.spokenDirhams(snapshot.spend))"
                                  : "\(monthName) spend, amount hidden"
        if let text = comparison?.text { spoken += ", \(text)" }
        return SpendWidgetContent(
            monthName: monthName, amount: amount, heroNumber: showsAmounts ? MoneyFormat.hero(snapshot.spend) : nil,
            pace: comparison?.text, paceShort: short, paceTone: comparison?.tone ?? .neutral,
            footnote: footnote, footnoteShort: footnoteShort, message: nil, inline: inline,
            accessibilityLabel: spoken)
    }

    static func message(_ text: String, monthName: String) -> SpendWidgetContent {
        SpendWidgetContent(monthName: monthName, amount: nil, heroNumber: nil, pace: nil, paceShort: nil,
                           paceTone: .neutral, footnote: nil, footnoteShort: nil, message: text,
                           inline: "Bank Ledger: open to refresh",
                           accessibilityLabel: text)
    }

    /// `"18% below the same day last month"` → `"18% below last month"`.
    static func shorten(_ text: String) -> String {
        text.replacingOccurrences(of: "the same day last month", with: "last month")
            .replacingOccurrences(of: "Nothing spent by this day last month", with: "Nothing by now last month")
    }
}

/// Words for the next-due widget.
public struct DueWidgetContent: Sendable, Equatable {
    /// The card whose statement is due next: `"FAB Cashback"`.
    public let card: String?
    /// `"Due in 5 days"` (`DueStatus`).
    public let when: String?
    public let whenTone: Tone
    /// `"20 Oct"`.
    public let date: String?
    /// The statement balance, `"AED 4,210.55"`; nil when hidden or unknown.
    public let amount: String?
    /// `"Min AED 210.53"`; nil when hidden or unknown.
    public let minimum: String?
    /// `"+1 more due by 28 Oct"`: other cards due later.
    public let others: String?
    public let footnote: String?
    /// Instead of a card: nothing upcoming, no statements yet, no snapshot.
    public let message: String?
    public let inline: String
    public let accessibilityLabel: String

    public static func make(snapshot: WidgetSnapshot?, placement: WidgetPlacement, requireAuth: Bool,
                            now: Date = .now) -> DueWidgetContent {
        guard let snapshot else { return .message("Open Bank Ledger to see what's due.") }
        let today = LedgerDates.today(now: now)
        let upcoming = WidgetDue.upcoming(snapshot.cards, today: today)
        guard let next = upcoming.first, let due = next.dueDate else {
            // A claim only the data can make: statements exist, none due ahead.
            let anyStatement = snapshot.cards.contains { $0.dueDate != nil }
            return .message(anyStatement ? "Nothing due. Every due date has passed." : "No statements yet.")
        }
        let showsAmounts = WidgetPrivacy.showsAmounts(on: placement, requireAuth: requireAuth)
        let status = DueStatus.describe(due: due, isLatest: true, today: today)
        let amount = showsAmounts ? next.closingBalance.map { MoneyFormat.aed($0) } : nil
        let minimum = showsAmounts ? next.minDue.map { "Min \(MoneyFormat.aed($0))" } : nil
        let rest = upcoming.dropFirst()
        let others: String? = rest.last?.dueDate.map { last in
            "+\(rest.count) more due by \(LedgerDates.dayLabel(last, today: today))"
        }
        let dateLabel = LedgerDates.dayLabel(due, today: today)
        let whenText = status?.text ?? dateLabel
        var spoken = "\(next.title), \(whenText.lowercased()), \(dateLabel)"
        if let amount { spoken += ", statement balance \(amount)" }
        return DueWidgetContent(
            card: next.title, when: whenText, whenTone: status?.tone ?? .neutral, date: dateLabel,
            amount: amount, minimum: minimum, others: others,
            footnote: showsAmounts ? nil : WidgetPrivacy.hiddenFootnote, message: nil,
            inline: "\(next.title) · \(whenText)", accessibilityLabel: spoken)
    }

    static func message(_ text: String) -> DueWidgetContent {
        DueWidgetContent(card: nil, when: nil, whenTone: .neutral, date: nil, amount: nil, minimum: nil,
                         others: nil, footnote: nil, message: text, inline: text, accessibilityLabel: text)
    }
}

/// Words for the utilisation widget. A percent is not an amount: it shows on
/// every placement.
public struct UtilisationWidgetContent: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String { accountCode }
        public let accountCode: String
        public let title: String
        /// `"14%"`.
        public let percent: String
        /// 0…1, clamped, for a bar or gauge.
        public let fraction: Double
        public let tone: Tone
    }

    /// Highest utilisation first.
    public let rows: [Row]
    public let message: String?
    public let inline: String

    public static func make(snapshot: WidgetSnapshot?) -> UtilisationWidgetContent {
        guard let snapshot else {
            return UtilisationWidgetContent(rows: [], message: "Open Bank Ledger to see utilisation.",
                                            inline: "Bank Ledger: open to refresh")
        }
        let rows = snapshot.cards
            .compactMap { card -> (WidgetSnapshot.Card, Decimal)? in card.utilisation.map { (card, $0) } }
            .sorted { $0.1 > $1.1 }
            .map { card, u in
                Row(accountCode: card.accountCode, title: card.title, percent: MoneyFormat.percent(u),
                    fraction: min(max(u.chartValue, 0), 1), tone: AccountSummary.utilisationTone(u))
            }
        guard let top = rows.first else {
            return UtilisationWidgetContent(rows: [], message: "No card has a limit and a statement yet.",
                                            inline: "Utilisation: no statements yet")
        }
        return UtilisationWidgetContent(rows: rows, message: nil, inline: "\(top.title) \(top.percent) used")
    }
}

/// Which statements are still to pay, soonest first. A past due date is left
/// out: whether it was paid isn't known on the phone (`DueStatus`).
public enum WidgetDue {
    public static func upcoming(_ cards: [WidgetSnapshot.Card], today: CalendarDay) -> [WidgetSnapshot.Card] {
        cards.enumerated()
            .filter { _, card in card.dueDate.map { today.days(until: $0) >= 0 } ?? false }
            .sorted { a, b in (a.element.dueDate!, a.offset) < (b.element.dueDate!, b.offset) }
            .map(\.element)
    }
}

enum WidgetFootnote {
    /// `"Home · updated 14:05"`, `"Home · updated 3 Oct"` from an earlier day;
    /// `"Updated 14:05"` without the ledger.
    static func updated(_ snapshot: WidgetSnapshot, today: CalendarDay, withLedger: Bool = true) -> String {
        let day = CalendarDay(date: snapshot.generatedAt)
        let when = day == today ? LedgerDates.timeLabel(snapshot.generatedAt) : LedgerDates.dayLabel(day, today: today)
        guard withLedger, let name = snapshot.ledgerName else { return "Updated \(when)" }
        return "\(name) · updated \(when)"
    }
}

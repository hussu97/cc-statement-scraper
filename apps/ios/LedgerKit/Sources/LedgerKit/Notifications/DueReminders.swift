import Foundation

/// Statement due reminders (N-1b): 3 days before and on the due date, at
/// 09:00 Dubai, for each account's latest statement that isn't paid. Pure:
/// the app target diffs the plan against the pending requests.
public enum DueReminders {
    static let idPrefix = "ledger.due."
    /// Cycles to read: plenty to include every account's latest statement.
    public static let cycleLimit = 100
    /// 09:00 in Asia/Dubai.
    static let hour = 9

    /// The reminders that should be pending now. A statement the server marks
    /// `paid` has none (so its pending ones are withdrawn by `sync`); a time
    /// already past is skipped. Without `payment_status` (an older server) the
    /// reminders stand: the phone can't tell a paid statement.
    public static func plan(cycles: [StatementCycle], now: Date = Date(),
                            preferences: NoticePreferences) -> [LocalNotice] {
        guard preferences.isOn(.dueReminder) else { return [] }
        let latest = StatementsModel.latestStatementCodes(cycles)
        return cycles
            .filter { latest.contains($0.stmtCode) && $0.kind == "statement" }
            .filter { $0.duePayment?.status != .paid }
            .flatMap { cycle -> [LocalNotice] in
                guard let due = cycle.dueDate else { return [] }
                return [(3, "t3"), (0, "t0")].compactMap { daysBefore, tag in
                    let fireAt = at9(due.adding(days: -daysBefore))
                    guard fireAt > now else { return nil }
                    return notice(cycle, due: due, daysBefore: daysBefore, id: "\(idPrefix)\(cycle.stmtCode).\(tag)",
                                  fireAt: fireAt)
                }
            }
            .sorted { ($0.fireAt ?? now, $0.id) < ($1.fireAt ?? now, $1.id) }
    }

    /// What the app does with the due reminders on coming to the foreground,
    /// or once a ledger is on screen.
    public enum Refresh: Equatable, Sendable {
        /// Load this ledger's statement cycles and sync the plan.
        case replan(profileCode: String)
        /// Signed out: withdraw every due reminder, pending and delivered.
        case withdrawAll
        /// Nothing is known about the ledger yet: leave what is scheduled.
        case keep
    }

    /// Only a loaded profile list with the selected ledger in it can replan.
    /// While the session restores, or the profiles are loading or failed to
    /// load (a cold or offline launch), nothing is selected yet, and planning
    /// from that would withdraw every reminder; they stay as scheduled. Only
    /// signing out withdraws them all.
    public static func refresh(phase: SessionStore.Phase, profiles: LoadState<[LedgerProfile]>,
                               selected: String?) -> Refresh {
        switch phase {
        case .signedOut:
            return .withdrawAll
        case .restoring, .awaitingCode:
            return .keep
        case .signedIn:
            guard case .loaded(let list) = profiles, let selected,
                  list.contains(where: { $0.profileCode == selected }) else { return .keep }
            return .replan(profileCode: selected)
        }
    }

    /// Signing out: every due reminder goes, scheduled or already in
    /// Notification Centre (the next account's ledger isn't this one).
    public static func withdrawAll(pendingIDs: [String], deliveredIDs: [String]) -> NoticeUpdate {
        NoticeUpdate(cancel: Set((pendingIDs + deliveredIDs).filter { $0.hasPrefix(idPrefix) }).sorted())
    }

    /// What to change, given the due-reminder requests pending now and those
    /// already delivered: withdraw the pending ones no longer planned (paid,
    /// superseded, switched off) and the delivered ones for a statement the
    /// server now marks paid (a "due today" for a paid card is wrong, not
    /// history), then post the plan (re-posting an id replaces it, so a
    /// changed amount is kept current). A delivered reminder for a statement
    /// still to pay stays in Notification Centre.
    public static func sync(pendingIDs: [String], deliveredIDs: [String] = [], planned: [LocalNotice],
                            cycles: [StatementCycle] = []) -> NoticeUpdate {
        let keep = Set(planned.map(\.id))
        let stale = pendingIDs.filter { $0.hasPrefix(idPrefix) && !keep.contains($0) }
        let paid = Set(cycles.filter { $0.duePayment?.status == .paid }.map(\.stmtCode))
        let paidDelivered = deliveredIDs.filter { id in statementCode(of: id).map(paid.contains) ?? false }
        return NoticeUpdate(post: planned, cancel: Set(stale + paidDelivered).sorted())
    }

    /// `"ledger.due.stm_x.t3"` → `"stm_x"`; nil for any other notification.
    static func statementCode(of id: String) -> String? {
        guard id.hasPrefix(idPrefix), let dot = id.lastIndex(of: "."),
              dot >= id.index(id.startIndex, offsetBy: idPrefix.count) else { return nil }
        let code = id[id.index(id.startIndex, offsetBy: idPrefix.count)..<dot]
        return code.isEmpty ? nil : String(code)
    }

    static func notice(_ cycle: StatementCycle, due: CalendarDay, daysBefore: Int, id: String,
                       fireAt: Date) -> LocalNotice {
        let card = cycle.title
        let title = daysBefore == 0 ? "\(card) is due today" : "\(card) is due in \(daysBefore) days"
        var parts: [String] = []
        if let minDue = cycle.minDue { parts.append("Minimum \(MoneyFormat.aed(minDue))") }
        if let balance = cycle.closingBalance { parts.append("statement balance \(MoneyFormat.aed(balance))") }
        if let paid = cycle.amountPaid, paid > 0 { parts.append("\(MoneyFormat.aed(paid)) paid so far") }
        let figures = parts.isEmpty ? "" : parts.joined(separator: ", ") + ". "
        let body = "\(figures)Due \(LedgerDates.fullDayLabel(due))."
        return LocalNotice(id: id, kind: .dueReminder, title: title, body: body, fireAt: fireAt)
    }

    /// 09:00 Dubai on `day`.
    static func at9(_ day: CalendarDay) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dubai")!
        let components = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour)
        return calendar.date(from: components)!
    }
}

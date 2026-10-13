import Foundation

/// Whether a statement was paid, as the server decides it (`payment_status`,
/// `amount_paid` on `overview.accounts[]` and `statement_cycles`). Both are
/// optional: an older server sends neither, and then the phone never claims a
/// statement was paid or overdue.
public struct DuePayment: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case paid
        case partPaid = "part_paid"
        case unpaid
        case overdue
    }

    public let status: Status
    /// What was paid towards the statement (AED), when the server says.
    public let amountPaid: Decimal?

    public init(status: Status, amountPaid: Decimal? = nil) {
        self.status = status
        self.amountPaid = amountPaid
    }

    /// Nil for a missing or unknown status (a newer server's value is not guessed at).
    public init?(status raw: String?, amountPaid: Decimal?) {
        guard let raw, let status = Status(rawValue: raw) else { return nil }
        self.init(status: status, amountPaid: amountPaid)
    }
}

/// Due-date wording shared by Overview and Statements. "Paid", "Part paid"
/// and "Overdue" come only from the server's `payment_status`; without it a
/// past due date is "Was due …", unless the caller *knows* no payment arrived
/// for the latest statement.
public enum DueStatus {
    /// - Parameters:
    ///   - isLatest: the account's newest statement. An older one was
    ///     superseded by a newer statement, so it is never overdue.
    ///   - payment: the server's payment status; nil from an older server.
    ///   - paymentDetected: nil when payment detection isn't available —
    ///     then a past due date is never called overdue.
    public static func describe(due: CalendarDay?, isLatest: Bool, payment: DuePayment? = nil,
                                paymentDetected: Bool? = nil,
                                today: CalendarDay = LedgerDates.today()) -> (text: String, tone: Tone)? {
        if let payment { return describe(payment, due: due, isLatest: isLatest, today: today) }
        guard let due else { return nil }
        let days = today.days(until: due)
        if days >= 0 {
            return (LedgerDates.dueLabel(due, today: today), days <= 5 ? .warn : .neutral)
        }
        if isLatest, paymentDetected == false {
            return (LedgerDates.dueLabel(due, today: today), .danger)
        }
        return (wasDue(due, today: today), .neutral)
    }

    private static func describe(_ payment: DuePayment, due: CalendarDay?, isLatest: Bool,
                                 today: CalendarDay) -> (text: String, tone: Tone)? {
        let paid = payment.amountPaid.flatMap { $0 > 0 ? MoneyFormat.aed($0) : nil }
        switch payment.status {
        case .paid:
            return ("Paid", .positive)
        case .partPaid:
            let head = paid.map { "Part paid (\($0))" } ?? "Part paid"
            guard let due else { return (head, .warn) }
            let when = today.days(until: due) >= 0 ? LedgerDates.dueLabel(due, today: today) : wasDue(due, today: today)
            return ("\(head) · \(when)", .warn)
        case .overdue:
            let head = due.map { today.days(until: $0) < 0 ? LedgerDates.dueLabel($0, today: today) : "Overdue" } ?? "Overdue"
            return (paid.map { "\(head) · \($0) paid" } ?? head, .danger)
        case .unpaid:
            return describe(due: due, isLatest: isLatest, paymentDetected: false, today: today)
        }
    }

    private static func wasDue(_ due: CalendarDay, today: CalendarDay) -> String {
        "Was due \(LedgerDates.dayLabel(due, today: today))"
    }
}

import Foundation
import Testing
@testable import LedgerKit

private func freshPreferences() -> NoticePreferences {
    NoticePreferences(defaults: UserDefaults(suiteName: "notices.\(UUID().uuidString)")!)
}

@Suite("Notifications: only captures that need the person (N-1a)")
struct CaptureNoticeTests {
    let now = Date(timeIntervalSince1970: 1_791_436_364)
    let body = "Purchase of AED 12.50 with Credit Card ending 1234 at SECRET MERCHANT"

    @Test("a routine outcome posts nothing (and withdraws the outbox reminder when nothing waits)", arguments: [
        SMSIntakeOutcome.delivered(status: "created"), .delivered(status: "duplicate"), .delivered(status: "held"),
        .dropped(.dropOTP), .refused(code: "invalid_amount", message: "x"),
    ])
    func routine(outcome: SMSIntakeOutcome) {
        let update = CaptureNotices.afterCapture(outcome, capture: .sms, outbox: OutboxStatus(),
                                                 preferences: freshPreferences(), now: now)
        #expect(update.post.isEmpty)
        #expect(update.cancel == ["ledger.outbox-stuck"])
    }

    @Test("unknown card from an SMS: points to Review, never quotes the message")
    func unknownCardSMS() throws {
        let update = CaptureNotices.afterCapture(.delivered(status: "unknown_card"), capture: .sms,
                                                 outbox: OutboxStatus(), preferences: freshPreferences(), now: now)
        let notice = try #require(update.post.first)
        #expect(notice.kind == .unknownCard && notice.link == .review && notice.fireAt == nil)
        #expect(!notice.body.contains("SECRET") && !notice.title.contains("SECRET"))
        #expect(!notice.body.contains("12.50"))
    }

    @Test("unknown card from a payment: names the card (cleaned) and points to Settings")
    func unknownCardPayment() throws {
        let update = CaptureNotices.afterCapture(.delivered(status: "unknown_card"), capture: .payment(card: "  Wio \n Credit "),
                                                 outbox: OutboxStatus(), preferences: freshPreferences(), now: now)
        let notice = try #require(update.post.first)
        #expect(notice.body.contains("“Wio Credit”"))
        #expect(notice.link == .settings)
    }

    @Test("signed out or no ledger while captures wait: one notice with the count", arguments: [
        SMSIntakeOutcome.QueueReason.signedOut, .noLedger,
    ])
    func signedOut(reason: SMSIntakeOutcome.QueueReason) throws {
        let status = OutboxStatus(awaitingLedger: 3)
        let update = CaptureNotices.afterCapture(.queued(reason), capture: .sms, outbox: status,
                                                 preferences: freshPreferences(), now: now)
        let notice = try #require(update.post.first)
        #expect(notice.kind == .signedOut)
        #expect(notice.body.hasPrefix("3 captures are waiting"))
    }

    @Test("offline: no notice now, a reminder an hour after the oldest capture")
    func stuckReminder() throws {
        let oldest = now.addingTimeInterval(-600)
        let status = OutboxStatus(pending: 2, oldest: oldest)
        let update = CaptureNotices.afterCapture(.queued(.offline), capture: .sms, outbox: status,
                                                 preferences: freshPreferences(), now: now)
        let notice = try #require(update.post.first)
        #expect(update.post.count == 1)
        #expect(notice.kind == .outboxStuck && notice.link == .settings)
        #expect(notice.fireAt == oldest.addingTimeInterval(3600))
        #expect(notice.body.hasPrefix("2 SMS or payments haven't"))
    }

    @Test("an hour already past: not re-posted; sent: withdrawn")
    func stuckPastOrSent() {
        let prefs = freshPreferences()
        let past = OutboxStatus(pending: 1, oldest: now.addingTimeInterval(-7200))
        #expect(CaptureNotices.outboxReminder(past, preferences: prefs, now: now) == NoticeUpdate())
        #expect(CaptureNotices.outboxReminder(OutboxStatus(), preferences: prefs, now: now)
                == NoticeUpdate(cancel: ["ledger.outbox-stuck"]))
    }

    @Test("a kind switched off posts nothing, and its reminder is withdrawn")
    func switchedOff() {
        let prefs = freshPreferences()
        for kind in NoticeKind.allCases { prefs.set(kind, on: false) }
        let status = OutboxStatus(pending: 1, oldest: now, awaitingLedger: 1)
        for outcome in [SMSIntakeOutcome.delivered(status: "unknown_card"), .queued(.signedOut), .queued(.offline)] {
            let update = CaptureNotices.afterCapture(outcome, capture: .sms, outbox: status, preferences: prefs, now: now)
            #expect(update.post.isEmpty)
            #expect(update.cancel == ["ledger.outbox-stuck"])
        }
    }

    @Test("preferences default on, persist, and switching off returns what to withdraw")
    @MainActor
    func settingsModel() {
        let defaults = UserDefaults(suiteName: "notices.\(UUID().uuidString)")!
        let model = NotificationSettingsModel(preferences: NoticePreferences(defaults: defaults))
        #expect(NoticeKind.allCases.allSatisfy(model.isOn))
        #expect(model.set(.unknownCard, on: false) == ["ledger.unknown-card"])
        #expect(model.set(.dueReminder, on: false) == [])
        #expect(model.set(.unknownCard, on: true) == [])
        #expect(!NoticePreferences(defaults: defaults).isOn(.dueReminder))
        #expect(NoticePreferences(defaults: defaults).isOn(.unknownCard))
        model.permissionChanged(.denied)
        #expect(model.permission.action == "Open iOS Settings")
        #expect(NoticePermission.allowed.action == nil)
    }
}

@MainActor
@Suite("ledger://settings: where a notification about a waiting capture lands")
struct SettingsLinkTests {
    @Test func opensSettingsTab() throws {
        let url = try #require(URL(string: "ledger://settings"))
        let link = try #require(AppLink(url: url))
        #expect(link == .settings)
        let router = TabRouter()
        router.open(link, ledgerOnScreen: true)
        #expect(router.tab == .settings && !router.showingReview)
    }
}

@Suite("Statement due reminders at T-3 and T-0, cancelled once paid (N-1b)")
struct DueReminderTests {
    /// 1 Oct 2026, 12:00 Dubai.
    let now = DueReminders.at9(CalendarDay(iso: "2026-10-01")!).addingTimeInterval(3 * 3600)

    func cycles(fabDue: String = "2026-10-20", fabExtra: String = "") throws -> [StatementCycle] {
        let json = """
        [{"stmt_code": "stm_fab_new", "account_code": "acc_fab", "bank_code": "FAB", "card_last4": "1234",
          "kind": "statement", "statement_date": "2026-09-25", "period_start": null, "period_end": null,
          "due_date": "\(fabDue)", "closing_balance": "4210.55", "min_due": "210.53", "credit_limit": null,
          "utilisation": null, "line_count": 3, "debits": 10, "credits": 0, "recon_status": null,
          "recon_checks": null, "doc_code": null\(fabExtra)},
         {"stmt_code": "stm_fab_old", "account_code": "acc_fab", "bank_code": "FAB", "card_last4": "1234",
          "kind": "statement", "statement_date": "2026-08-25", "period_start": null, "period_end": null,
          "due_date": "2026-10-03", "closing_balance": "100", "min_due": "25", "credit_limit": null,
          "utilisation": null, "line_count": 3, "debits": 10, "credits": 0, "recon_status": null,
          "recon_checks": null, "doc_code": null},
         {"stmt_code": "stm_adcb", "account_code": "acc_adcb", "bank_code": "ADCB", "card_last4": null,
          "kind": "statement", "statement_date": "2026-09-10", "period_start": null, "period_end": null,
          "due_date": "2026-10-02", "closing_balance": null, "min_due": null, "credit_limit": null,
          "utilisation": null, "line_count": 0, "debits": 0, "credits": 0, "recon_status": null,
          "recon_checks": null, "doc_code": null}]
        """
        return try LedgerJSON.decode([StatementCycle].self, from: Data(json.utf8))
    }

    @Test("latest statement per account, T-3 and T-0 at 09:00 Dubai; past times skipped")
    func plan() throws {
        let plan = DueReminders.plan(cycles: try cycles(), now: now, preferences: freshPreferences())
        // ADCB is due 2 Oct: T-3 (29 Sep) has passed, T-0 hasn't. FAB's older statement is superseded.
        #expect(plan.map(\.id) == ["ledger.due.stm_adcb.t0", "ledger.due.stm_fab_new.t3", "ledger.due.stm_fab_new.t0"])
        let t3 = plan[1]
        #expect(t3.fireAt == DueReminders.at9(CalendarDay(iso: "2026-10-17")!))
        #expect(t3.title == "FAB •1234 is due in 3 days")
        #expect(t3.body == "Minimum AED 210.53, statement balance AED 4,210.55. Due 20 Oct 2026.")
        #expect(plan[2].title == "FAB •1234 is due today")
        #expect(plan[0].body == "Due 2 Oct 2026.")
        // 09:00 in Dubai is 05:00 UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(utc.component(.hour, from: t3.fireAt!) == 5)
    }

    @Test("paid: no reminders, and the pending ones are withdrawn")
    func paid() throws {
        let paid = try cycles(fabExtra: #", "payment_status": "paid", "amount_paid": "4210.55""#)
        let plan = DueReminders.plan(cycles: paid, now: now, preferences: freshPreferences())
        #expect(plan.map(\.id) == ["ledger.due.stm_adcb.t0"])
        let sync = DueReminders.sync(pendingIDs: ["ledger.due.stm_fab_new.t3", "ledger.due.stm_fab_new.t0",
                                                  "ledger.due.stm_adcb.t0", "ledger.outbox-stuck"], planned: plan)
        #expect(sync.cancel == ["ledger.due.stm_fab_new.t0", "ledger.due.stm_fab_new.t3"])
        #expect(sync.post.map(\.id) == ["ledger.due.stm_adcb.t0"])
    }

    @Test("part paid: still reminded, with what was paid")
    func partPaid() throws {
        let part = try cycles(fabExtra: #", "payment_status": "part_paid", "amount_paid": "1000""#)
        let plan = DueReminders.plan(cycles: part, now: now, preferences: freshPreferences())
        #expect(plan.first { $0.id.hasSuffix("fab_new.t0") }?.body
                == "Minimum AED 210.53, statement balance AED 4,210.55, AED 1,000.00 paid so far. Due 20 Oct 2026.")
    }

    @Test("switched off: nothing planned, so every due reminder is withdrawn")
    func off() throws {
        let prefs = freshPreferences()
        prefs.set(.dueReminder, on: false)
        let plan = DueReminders.plan(cycles: try cycles(), now: now, preferences: prefs)
        #expect(plan.isEmpty)
        #expect(DueReminders.sync(pendingIDs: ["ledger.due.stm_adcb.t0"], planned: plan).cancel == ["ledger.due.stm_adcb.t0"])
    }
}

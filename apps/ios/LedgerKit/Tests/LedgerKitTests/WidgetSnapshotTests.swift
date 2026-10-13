import Foundation
import Testing
@testable import LedgerKit

/// 2026-10-13 12:00 in Dubai.
let widgetNow = CalendarDay(year: 2026, month: 10, day: 13).startDate.addingTimeInterval(12 * 3600)

func widgetSnapshot(now: Date = widgetNow, name: String? = "Home") throws -> WidgetSnapshot {
    let overview = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
    return try #require(WidgetSnapshot.make(overview: overview, profileCode: "prf_a", ledgerName: name, now: now))
}

func card(_ code: String, due: String?, balance: String? = "100.00", utilisation: String? = nil,
          payment: String? = nil, paid: String? = nil) -> WidgetSnapshot.Card {
    WidgetSnapshot.Card(accountCode: code, title: "Card \(code)", dueDate: due.flatMap(CalendarDay.init(iso:)),
                        closingBalance: balance.flatMap(LedgerDecimal.parse), minDue: nil,
                        utilisation: utilisation.flatMap(LedgerDecimal.parse), paymentStatus: payment,
                        amountPaid: paid.flatMap(LedgerDecimal.parse))
}

func snapshot(cards: [WidgetSnapshot.Card], month: CalendarDay = CalendarDay(year: 2026, month: 10, day: 1)) -> WidgetSnapshot {
    WidgetSnapshot(generatedAt: widgetNow, profileCode: "prf_a", ledgerName: "Home", month: month, spend: 860,
                   spendPrevMonthToDate: 1000, changeVsPrevMonthToDate: LedgerDecimal.parse("-0.14"),
                   uncategorizedCount: 0, cards: cards)
}

@Suite("Widget snapshot: the App Group file the widgets read (N-2)")
struct WidgetSnapshotTests {
    @Test("copies the server's figures for the current month; money round-trips as decimal strings")
    func makeAndRoundTrip() throws {
        let s = try widgetSnapshot()
        #expect(s.spend == LedgerDecimal.parse("1234567.89"))
        #expect(s.changeVsPrevMonthToDate == LedgerDecimal.parse("-0.1805"))
        #expect(s.cards.map(\.title) == ["FAB Cashback", "ADCB"])
        #expect(s.cards[0].dueDate == CalendarDay(iso: "2026-10-20"))
        #expect(s.cards[0].minDue == LedgerDecimal.parse("210.53"))
        #expect(s.cards[1].dueDate == nil && s.cards[1].utilisation == nil)

        let data = try s.encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""spend":"1234567.89""#))
        #expect(json.contains(#""closing_balance":"4210.55""#))
        #expect(WidgetSnapshot.decode(data) == s)
    }

    @Test("a past month never becomes the widgets' snapshot")
    func pastMonth() throws {
        let overview = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let november = CalendarDay(year: 2026, month: 11, day: 2).startDate
        #expect(WidgetSnapshot.make(overview: overview, profileCode: "prf_a", ledgerName: nil, now: november) == nil)
    }

    @Test("an unknown version or garbage reads as no snapshot")
    func unreadable() throws {
        #expect(WidgetSnapshot.decode(Data("nope".utf8)) == nil)
        let s = try widgetSnapshot()
        var object = try #require(try JSONSerialization.jsonObject(with: s.encoded()) as? [String: Any])
        object["version"] = 99
        #expect(WidgetSnapshot.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
    }

    @Test("reloads when the figures change or the file is half an hour old, not for an identical refresh")
    func reloadPolicy() throws {
        let s = try widgetSnapshot()
        #expect(s.needsReload(replacing: nil))
        let again = try widgetSnapshot(now: widgetNow.addingTimeInterval(60))
        #expect(again.sameContent(as: s))
        #expect(!again.needsReload(replacing: s))
        #expect(try widgetSnapshot(now: widgetNow.addingTimeInterval(31 * 60)).needsReload(replacing: s))
        #expect(try widgetSnapshot(name: "Work").needsReload(replacing: s))
    }

    @Test("the store writes, reads, skips an identical write, mirrors the privacy flag and clears")
    func store() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-widgets-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: "ledger-widgets-\(UUID().uuidString)"))
        let reloads = NameLog()
        let store = WidgetSnapshotStore(container: dir, defaults: defaults, reload: { reloads.append("reload") })
        #expect(store.read() == nil)
        let s = try widgetSnapshot()
        #expect(store.write(s))
        #expect(store.read() == s)
        #expect(!store.write(try widgetSnapshot(now: widgetNow.addingTimeInterval(60))))
        #expect(reloads.all.count == 1)

        #expect(!store.hidesLockScreenAmounts)
        store.hidesLockScreenAmounts = true
        store.hidesLockScreenAmounts = true
        #expect(store.hidesLockScreenAmounts)
        #expect(reloads.all.count == 2)

        store.clear()
        #expect(store.read() == nil)
        store.clear()
        #expect(reloads.all.count == 3)
    }

    @Test("Require Face ID is mirrored to the widgets at launch and on every change")
    @MainActor func lockMirrors() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ledger-lock-mirror-\(UUID().uuidString)"))
        defaults.set(true, forKey: AppLock.requireKey)
        let seen = NameLog()
        let lock = AppLock(defaults: defaults, authenticator: AlwaysPasses(),
                           onRequireChanged: { seen.append("\($0)") })
        #expect(seen.all == ["true"])
        await lock.setRequireAuth(false)
        #expect(seen.all == ["true", "false"])
    }
}

private struct AlwaysPasses: DeviceAuthenticating {
    func availableMethod() async -> DeviceAuthMethod? { .faceID }
    func authenticate(reason: String) async -> Bool { true }
}

@Suite("Widget content: what each widget says, and the Lock Screen privacy decision (N-2)")
struct WidgetContentTests {
    @Test("Lock Screen widgets draw no amounts when Require Face ID is on; the Home Screen always does")
    func privacy() {
        #expect(WidgetPrivacy.showsAmounts(on: .homeScreen, requireAuth: false))
        #expect(WidgetPrivacy.showsAmounts(on: .homeScreen, requireAuth: true))
        #expect(WidgetPrivacy.showsAmounts(on: .lockScreen, requireAuth: false))
        #expect(!WidgetPrivacy.showsAmounts(on: .lockScreen, requireAuth: true))
    }

    @Test("month spend: the amount, the server's pace in words, the ledger and when it was updated")
    func spend() throws {
        let c = SpendWidgetContent.make(snapshot: try widgetSnapshot(), placement: .homeScreen, requireAuth: false,
                                        now: widgetNow)
        #expect(c.monthName == "October")
        #expect(c.amount == "AED 1,234,568")
        #expect(c.heroNumber == "1,234,568")
        #expect(c.pace == "18% below the same day last month")
        #expect(c.paceShort == "18% below last month")
        #expect(c.paceTone == .positive)
        #expect(c.footnote == "Home · updated 12:00")
        #expect(c.footnoteShort == "Updated 12:00")
        #expect(c.inline == "October AED 1,234,568 · 18% below last month")
        #expect(c.message == nil)
    }

    @Test("month spend on a locked-down Lock Screen keeps the pace and drops every amount")
    func spendHidden() throws {
        let c = SpendWidgetContent.make(snapshot: try widgetSnapshot(), placement: .lockScreen, requireAuth: true,
                                        now: widgetNow)
        #expect(c.amount == nil && c.heroNumber == nil)
        #expect(c.paceShort == "18% below last month")
        #expect(c.footnote == WidgetPrivacy.hiddenFootnote && c.footnoteShort == nil)
        #expect(c.inline == "October · 18% below last month")
        #expect(!c.accessibilityLabel.contains("dirham"))
    }

    @Test("no snapshot, or one from last month: open the app, never last month's figures as this month's")
    func spendMissing() throws {
        let none = SpendWidgetContent.make(snapshot: nil, placement: .homeScreen, requireAuth: false, now: widgetNow)
        #expect(none.message == "Open Bank Ledger to see this month's spend." && none.amount == nil)
        let november = CalendarDay(year: 2026, month: 11, day: 1).startDate.addingTimeInterval(3600)
        let stale = SpendWidgetContent.make(snapshot: try widgetSnapshot(), placement: .homeScreen,
                                            requireAuth: false, now: november)
        #expect(stale.message == "Open Bank Ledger to load November." && stale.amount == nil)
    }

    @Test("an earlier day's snapshot says which day it is from")
    func footnoteDay() throws {
        let c = SpendWidgetContent.make(snapshot: try widgetSnapshot(), placement: .homeScreen, requireAuth: false,
                                        now: widgetNow.addingTimeInterval(2 * 86_400))
        #expect(c.footnote == "Home · updated 13 Oct")
    }

    @Test("next due: the soonest upcoming statement, its balance and minimum, and how many follow")
    func due() throws {
        let c = DueWidgetContent.make(snapshot: try widgetSnapshot(), placement: .homeScreen, requireAuth: false,
                                      now: widgetNow)
        #expect(c.card == "FAB Cashback")
        #expect(c.when == "Due in 7 days")
        #expect(c.date == "20 Oct")
        #expect(c.amount == "AED 4,210.55")
        #expect(c.minimum == "Min AED 210.53")
        #expect(c.others == nil)
        #expect(c.inline == "FAB Cashback · Due in 7 days")

        let hidden = DueWidgetContent.make(snapshot: try widgetSnapshot(), placement: .lockScreen, requireAuth: true,
                                           now: widgetNow)
        #expect(hidden.when == "Due in 7 days" && hidden.amount == nil && hidden.minimum == nil)
        #expect(!hidden.accessibilityLabel.contains("AED"))
    }

    @Test("upcoming dues sort soonest first; past ones are left out; ties keep the server's order")
    func dueOrder() {
        let today = CalendarDay(year: 2026, month: 10, day: 13)
        let cards = [card("a", due: "2026-10-28"), card("b", due: "2026-10-10"), card("c", due: "2026-10-15"),
                     card("d", due: nil), card("e", due: "2026-10-15")]
        #expect(WidgetDue.upcoming(cards, today: today).map(\.accountCode) == ["c", "e", "a"])
        let c = DueWidgetContent.make(snapshot: snapshot(cards: cards), placement: .homeScreen, requireAuth: false,
                                      now: widgetNow)
        #expect(c.card == "Card c" && c.when == "Due in 2 days" && c.others == "+2 more due by 28 Oct")
    }

    @Test("nothing due is said only when statements prove it")
    func dueEmpty() {
        let past = DueWidgetContent.make(snapshot: snapshot(cards: [card("b", due: "2026-10-10")]),
                                         placement: .homeScreen, requireAuth: false, now: widgetNow)
        #expect(past.message == "Nothing due. Every due date has passed.")
        let none = DueWidgetContent.make(snapshot: snapshot(cards: [card("d", due: nil)]),
                                         placement: .homeScreen, requireAuth: false, now: widgetNow)
        #expect(none.message == "No statements yet.")
        #expect(DueWidgetContent.make(snapshot: nil, placement: .homeScreen, requireAuth: false).message
                == "Open Bank Ledger to see what's due.")
    }

    @Test("utilisation: highest first, as the server's percent, with Overview's tones; shown everywhere")
    func utilisation() {
        let s = snapshot(cards: [card("a", due: nil, utilisation: "0.1404"), card("b", due: nil),
                                 card("c", due: nil, utilisation: "0.82"), card("d", due: nil, utilisation: "1.3")])
        let c = UtilisationWidgetContent.make(snapshot: s)
        #expect(c.rows.map(\.accountCode) == ["d", "c", "a"])
        #expect(c.rows.map(\.percent) == ["130%", "82%", "14%"])
        #expect(c.rows.map(\.tone) == [.danger, .danger, .positive])
        #expect(c.rows[0].fraction == 1)
        #expect(c.inline == "Card d 130% used")
        #expect(UtilisationWidgetContent.make(snapshot: snapshot(cards: [card("b", due: nil)])).message
                == "No card has a limit and a statement yet.")
    }

    @Test("timelines roll over at the next Dubai midnight")
    func refresh() {
        #expect(WidgetTimeline.nextRefresh(after: widgetNow) == CalendarDay(year: 2026, month: 10, day: 14).startDate)
    }
}

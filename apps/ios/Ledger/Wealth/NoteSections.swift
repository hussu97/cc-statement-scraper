import LedgerKit
import SwiftUI

/// What a note can pay: best and worst case, coupons still to come and break-even; each autocall
/// date if every share is at the trigger; and the maturity payout by where the worst share ends.
struct NoteScenariosCard: View {
    let note: NoteDetail

    var body: some View {
        if let s = note.scenarios {
            StatGrid(stats: note.scenarioStats)
            if !s.autocall.isEmpty {
                Card {
                    SectionHeader(title: "You win: called early")
                    Text("If every share is at the trigger on that date (coupons up to it paid).")
                        .font(Typography.caption).foregroundStyle(Palette.muted)
                    ForEach(s.autocall) { r in
                        if r.id != s.autocall.first?.id { Divider().overlay(Palette.border) }
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LedgerDates.fullDayLabel(r.obsDate)).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                                Text("Trigger \(NoteText.pct(r.triggerPct))"
                                     + (r.annualisedPct.map { " · \(NoteText.pct($0)) a year" } ?? ""))
                                    .font(Typography.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(note.summary.money(r.total)).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                                Text(note.summary.signed(r.profit)).font(Typography.caption)
                                    .foregroundStyle(NoteText.profitTone(r.profit).color).moneyLine()
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Card {
                SectionHeader(title: "At maturity")
                Text("By where the worst share ends:").font(Typography.caption).foregroundStyle(Palette.muted)
                ForEach(NoteText.payoutRows(note.payout), id: \.when) { row in
                    Text("\(row.when): \(row.pays)\(row.physical ? " in shares" : "")")
                        .font(Typography.caption).foregroundStyle(Palette.ink2)
                }
                ForEach(note.maturityRows) { p in
                    Divider().overlay(Palette.border)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Worst \(NoteText.pct(p.worstPct))").font(Typography.rowMeta).foregroundStyle(Palette.ink)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(note.summary.money(p.amount) + (p.settlement == "physical" && p.amount > 0 ? " in shares" : ""))
                                .font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                            Text(note.summary.signed(p.profit)).font(Typography.caption)
                                .foregroundStyle(NoteText.profitTone(p.profit).color).moneyLine()
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Profit counts the coupons received so far, not future ones.")
                    .font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

/// Every observation date with its coupon and autocall terms, and what happened on it.
struct NoteScheduleCard: View {
    let note: NoteDetail

    var body: some View {
        Card {
            Text(note.scheduleCaption.uppercased()).font(Typography.caption).tracking(1).foregroundStyle(Palette.muted)
            SectionHeader(title: "Schedule and outcomes")
            if note.observations.isEmpty {
                Text("Only the final valuation on \(LedgerDates.fullDayLabel(note.terms.finalValuationDate)).")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(note.scheduleRows) { row in
                if row.id != note.scheduleRows.first?.id { Divider().overlay(Palette.border) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(LedgerDates.fullDayLabel(row.obsDate)).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                        Spacer(minLength: 8)
                        Text("paid \(LedgerDates.dayLabel(row.payDate))").font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    if let coupon = row.coupon {
                        Text("Coupon \(coupon)").font(Typography.caption).foregroundStyle(Palette.ink2)
                    }
                    if let call = row.autocall {
                        Text("Autocall \(call)").font(Typography.caption).foregroundStyle(Palette.ink2)
                    }
                    ForEach(row.outcomes, id: \.self) { line in
                        Text(line.text).font(Typography.caption).foregroundStyle(line.tone.color)
                    }
                    if let pending = row.pending {
                        Text(pending).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The terms as read from the term sheet.
struct NoteTermsCard: View {
    let note: NoteDetail

    var body: some View {
        Card {
            Text("AS READ FROM THE TERM SHEET").font(Typography.caption).tracking(1).foregroundStyle(Palette.muted)
            SectionHeader(title: "Terms")
            ForEach(note.termRows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label).font(Typography.caption).foregroundStyle(Palette.muted)
                    Text(row.value).font(Typography.rowMeta).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

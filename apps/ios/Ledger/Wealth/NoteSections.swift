import LedgerKit
import SwiftUI

/// Figures with their labels and the line under each, `columns` to a row.
struct StatTiles: View {
    let stats: [NoteStat]
    var columns = 2

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: columns),
                  alignment: .leading, spacing: 16) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 3) {
                    Text(stat.label).font(Typography.caption).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(stat.value).font(Typography.amount)
                        .foregroundStyle(stat.tone == .neutral ? Palette.ink : stat.tone.color).moneyLine()
                    if let sub = stat.sub {
                        Text(sub).font(Typography.caption)
                            .foregroundStyle(stat.tone == .neutral ? Palette.muted : stat.tone.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// "All scenarios": best and worst case, coupons still to come and break-even; each autocall
/// date if every stock is at the trigger; and the maturity payout by where the worst stock ends.
struct NoteScenariosContent: View {
    let note: NoteDetail

    var body: some View {
        if let s = note.scenarios {
            VStack(alignment: .leading, spacing: 12) {
                StatTiles(stats: note.scenarioStats)
                if !s.autocall.isEmpty {
                    Divider().overlay(Palette.border)
                    Text("Called early").font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Text("If every stock is at the trigger on that date (coupons up to it paid).")
                        .font(Typography.caption).foregroundStyle(Palette.muted)
                    ForEach(s.autocall) { r in
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
                Divider().overlay(Palette.border)
                Text("At maturity").font(Typography.rowTitle).foregroundStyle(Palette.ink)
                Text("By where the lowest stock ends (as % of its start):").font(Typography.caption).foregroundStyle(Palette.muted)
                ForEach(NoteText.payoutRows(note.payout), id: \.when) { row in
                    Text("\(row.when): \(row.pays)\(row.physical ? " in shares" : "")")
                        .font(Typography.caption).foregroundStyle(Palette.ink2)
                }
                ForEach(note.maturityRows) { p in
                    HStack(alignment: .firstTextBaseline) {
                        Text("Lowest stock at \(NoteText.pct(p.worstPct))").font(Typography.rowMeta).foregroundStyle(Palette.ink)
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

/// "Full schedule": the schedule in one line, then every observation date with its coupon and
/// autocall terms and what happened on it.
struct NoteScheduleContent: View {
    let note: NoteDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.scheduleSummary).font(Typography.caption).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if note.observations.isEmpty {
                Text("Only the final valuation on \(LedgerDates.fullDayLabel(note.terms.finalValuationDate)).")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(note.scheduleRows) { row in
                Divider().overlay(Palette.border)
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

/// "Terms": as read from the term sheet.
struct NoteTermsContent: View {
    let note: NoteDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

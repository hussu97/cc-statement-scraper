import Charts
import LedgerKit
import SwiftUI

/// The shares a note follows: each one's initial level, last close and level now, and (while it
/// is live) how far it is from the autocall, the coupon barrier and break-even; then the worst
/// share against each level, and the closes since the strike in % of the initial level.
struct NoteSharesCard: View {
    let note: NoteDetail

    var body: some View {
        Card {
            Text("THE SHARES IT FOLLOWS").font(Typography.caption).tracking(1).foregroundStyle(Palette.muted)
            SectionHeader(title: "Against the barriers")
            ForEach(note.underlyings) { u in
                if u.id != note.underlyings.first?.id { Divider().overlay(Palette.border) }
                ShareBlock(share: u, live: !note.isEnded)
            }
            if let intro = note.levelsIntro, let levels = note.levels {
                Divider().overlay(Palette.border)
                Text(intro).font(Typography.caption).foregroundStyle(Palette.muted)
                ForEach(levels) { level in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(NoteText.levelLabel(level)).font(Typography.rowMeta).foregroundStyle(Palette.ink2)
                            Text("\(NoteText.pct(level.pct)), \(LedgerDates.dayLabel(level.date))")
                                .font(Typography.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 8)
                        Text(NoteText.distance(level.distancePct)).font(Typography.amount)
                            .foregroundStyle(NoteText.distanceMet(level.distancePct) ? Palette.positive : Palette.warn)
                            .moneyLine()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            let lines = note.seriesLines
            if !lines.isEmpty {
                Divider().overlay(Palette.border)
                NoteChart(lines: lines, levels: note.isEnded ? [] : note.levels ?? [])
            }
        }
    }
}

/// One share: symbol and name (worst flagged), initial → last close, level, and its distances.
private struct ShareBlock: View {
    let share: NoteDetail.Underlying
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(share.symbol).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                if share.isWorst && live { Chip(label: "worst", tone: .warn) }
                Spacer(minLength: 8)
                Text(NoteText.pct(share.perfPct, digits: 2)).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
            }
            Text(share.name).font(Typography.caption).foregroundStyle(Palette.muted)
            Text(closeLine).font(Typography.caption).foregroundStyle(Palette.muted)
            if live {
                distance("Autocall", share.toAutocallPct, share.autocallLevel)
                distance("Coupon", share.toCouponPct, share.couponLevel)
                distance("Break-even", share.toBreakEvenPct, share.breakEvenLevel)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var closeLine: String {
        let close = share.close.map(MoneyFormat.plain) ?? "—"
        let when = share.closeDate.map { " (\(LedgerDates.dayLabel($0)))" } ?? ""
        return "Initial \(MoneyFormat.plain(share.initial)) · last close \(close)\(when)"
    }

    @ViewBuilder private func distance(_ label: String, _ d: Decimal?, _ level: Decimal?) -> some View {
        if d != nil {
            HStack(alignment: .firstTextBaseline) {
                Text(label + (level.map { " at \(MoneyFormat.plain($0))" } ?? ""))
                    .font(Typography.caption).foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                Text(NoteText.distance(d)).font(Typography.caption.weight(.medium))
                    .foregroundStyle(NoteText.distanceMet(d) ? Palette.positive : Palette.warn)
            }
        }
    }
}

/// Each share's closes since the strike in % of its initial level, with the live levels as rules.
private struct NoteChart: View {
    let lines: [NoteSeriesLine]
    let levels: [NoteDetail.Level]
    private static let colors: [Color] = [ChartPalette.cat4, ChartPalette.cat1, ChartPalette.cat7, ChartPalette.cat12,
                                          ChartPalette.cat3, ChartPalette.cat9]

    var body: some View {
        Chart {
            ForEach(lines) { line in
                ForEach(line.points, id: \.day) { p in
                    LineMark(x: .value("Day", p.day.startDate), y: .value("% of initial", p.pct.chartValue))
                        .foregroundStyle(by: .value("Share", line.symbol))
                        .interpolationMethod(.linear)
                }
            }
            ForEach(levels) { level in
                RuleMark(y: .value(NoteText.levelLabel(level), level.pct.chartValue))
                    .foregroundStyle(Palette.borderStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale(domain: lines.map(\.symbol), range: Array(Self.colors.prefix(max(lines.count, 1))))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(ChartPalette.grid)
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .environment(\.timeZone, LedgerDates.timeZone)
        .environment(\.calendar, LedgerDates.calendar)
        .frame(height: 220)
        .accessibilityLabel("Each share's closes since the strike, in percent of its initial level")
    }
}

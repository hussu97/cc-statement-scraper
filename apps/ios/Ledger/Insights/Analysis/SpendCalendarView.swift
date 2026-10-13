import LedgerKit
import SwiftUI

/// Daily spending as a calendar heatmap (web Insights › Calendar, BACKLOG PAR-12): one month per
/// block, newest first, Monday to Sunday. Tap a day for its total; "Open this day in Activity"
/// lists its transactions. `SpendCalendar` (LedgerKit) lays it out and shades it.
struct SpendCalendarView: View {
    let range: AnalysisRange
    let profileCode: String
    @Environment(AnalysisScreens.self) private var screens
    @Environment(TabRouter.self) private var tabs: TabRouter?
    @State private var loader: AnalysisLoader<AnalysisRange, SpendCalendar>?
    @State private var selected: CalendarDay?

    var body: some View {
        Page {
            if let loader {
                StateContainer(state: loader.state, retry: reload) { calendar in
                    Text(calendar.rangeLabel()).font(Typography.caption).foregroundStyle(Palette.muted)
                        .padding(.top, 8)
                    if calendar.isEmpty {
                        AnalysisEmptyCard(systemImage: "calendar", title: "No spending in this range",
                                          message: "Pick a longer period to see your spending day by day.")
                    } else {
                        ReadoutCard(calendar: calendar, selected: selected) { day in tabs?.openActivity(.onDay(day)) }
                        ForEach(calendar.months) { month in
                            MonthCard(month: month, selected: $selected)
                        }
                    }
                }
            } else {
                LoadingCard()
            }
        }
        .ledgerNavigation("Daily spending")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: AnalysisTaskKey(profileCode: profileCode, request: range)) {
            let l = loader ?? screens.calendar()
            loader = l
            await l.loadIfNeeded(profileCode: profileCode, request: range)
        }
        .refreshable { await loader?.load(profileCode: profileCode, request: range) }
    }

    private func reload() {
        guard let loader else { return }
        Task { await loader.load(profileCode: profileCode, request: range) }
    }
}

/// The selected day's total and a way into its transactions; before a tap, how many days had spend.
private struct ReadoutCard: View {
    let calendar: SpendCalendar
    let selected: CalendarDay?
    let openDay: (CalendarDay) -> Void

    var body: some View {
        Card {
            if let day = selected, let cell = calendar.cell(for: day) {
                AdaptiveRow(alignment: .firstTextBaseline) {
                    Text(AnalysisFormat.dayTitle(cell.day)).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                } trailing: {
                    Text(AnalysisFormat.total(cell.amount)).font(Typography.amount).moneyLine()
                }
                Text(AnalysisFormat.count(cell.txnCount, "transaction"))
                    .font(Typography.caption).foregroundStyle(Palette.muted)
                Button { openDay(day) } label: {
                    Label("Open this day in Activity", systemImage: "list.bullet")
                        .font(Typography.body)
                        .frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
                .accessibilityHint("Shows this day's transactions in Activity")
            } else {
                Text(calendar.summary).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                Text("Tap a day for its total and transactions.").font(Typography.caption).foregroundStyle(Palette.muted)
            }
            HeatLegend()
        }
    }
}

/// One month: weekday headings, then a row of seven cells per week.
private struct MonthCard: View {
    let month: SpendCalendar.Month
    @Binding var selected: CalendarDay?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        Card {
            Text(month.title).font(Typography.cardTitle).foregroundStyle(Palette.ink)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(AnalysisFormat.weekdays, id: \.self) { name in
                    Text(String(name.prefix(2))).font(Typography.caption).foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                }
                ForEach(Array(month.weeks.joined().enumerated()), id: \.offset) { _, cell in
                    if let cell {
                        DayCell(cell: cell, isSelected: selected == cell.day) {
                            selected = selected == cell.day ? nil : cell.day
                        }
                    } else {
                        Color.clear.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let cell: SpendCalendar.Cell
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HeatCell(level: cell.level)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Text(cell.dayNumber)
                        .font(Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(cell.level >= 3 ? Palette.accentInk : Palette.ink2)
                }
                .overlay {
                    if isSelected { RoundedRectangle(cornerRadius: 4).stroke(Palette.ink, lineWidth: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SpendCalendar.label(cell))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

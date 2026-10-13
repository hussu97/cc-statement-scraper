import LedgerKit
import SwiftUI

/// Insights' "More analysis" card (BACKLOG PAR-12): the screens the web shows as Insights tabs
/// (calendar, time of day, year over year, foreign currency), over the period Insights shows.
struct AnalysisLinksCard: View {
    let range: AnalysisRange
    let profileCode: String

    var body: some View {
        Card {
            SectionHeader(title: "More analysis", trailing: range.label())
            link("Daily spending", systemImage: "calendar", detail: "Every day of the period, shaded by what you spent") {
                SpendCalendarView(range: range, profileCode: profileCode)
            }
            Divider().overlay(Palette.border)
            link("When you spend", systemImage: "clock", detail: "Weekday and hour, from bank SMS times") {
                HourPatternView(range: range, profileCode: profileCode)
            }
            Divider().overlay(Palette.border)
            link("Year over year", systemImage: "chart.bar.xaxis", detail: "Each month against the same month last year") {
                YearOverYearView(profileCode: profileCode)
            }
            Divider().overlay(Palette.border)
            link("Foreign currency", systemImage: "airplane", detail: "Spending in other currencies and the rate you paid") {
                ForeignSpendView(range: range, profileCode: profileCode)
            }
        }
    }

    private func link<Destination: View>(_ title: String, systemImage: String, detail: String,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(Palette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.subtle)
            }
            .frame(minHeight: Metrics.tapMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// `See all subscriptions ›` under Insights' recurring card: every `recurring_list` row,
/// ended and dismissed ones included (web Subscriptions tab).
struct SubscriptionsSeeAllLink: View {
    let charges: [RecurringCharge]

    var body: some View {
        NavigationLink {
            SubscriptionsView(charges: charges)
        } label: {
            HStack(spacing: 4) {
                Text("See all subscriptions")
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(Typography.rowMeta)
            .foregroundStyle(Palette.accent)
            .frame(maxWidth: .infinity, minHeight: Metrics.tapMin, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One heatmap cell's shade: surface-2 with the accent mixed in by level (web `heatFill`).
struct HeatCell: View {
    let level: Int
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Palette.surface2)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill(Palette.accent.opacity(HeatScale.intensity(level))))
    }
}

/// `Less ▢▢▢▢▢ More` (web `HeatLegend`).
struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Less").font(Typography.caption).foregroundStyle(Palette.muted)
            ForEach(0...HeatScale.levels, id: \.self) { level in
                HeatCell(level: level, cornerRadius: 3).frame(width: 12, height: 12)
            }
            Text("More").font(Typography.caption).foregroundStyle(Palette.muted)
        }
        .accessibilityHidden(true)
    }
}

/// A screen's empty state: what isn't there, and what would fill it.
struct AnalysisEmptyCard: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        Card {
            Label(title, systemImage: systemImage).font(Typography.cardTitle).foregroundStyle(Palette.ink)
            Text(message).font(Typography.rowMeta).foregroundStyle(Palette.muted)
        }
    }
}

/// What a screen's `.task(id:)` loads for: the ledger and the range (or year).
struct AnalysisTaskKey<Request: Hashable>: Hashable {
    let profileCode: String
    let request: Request
}

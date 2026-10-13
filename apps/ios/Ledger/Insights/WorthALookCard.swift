import LedgerKit
import SwiftUI

/// Insights' way into "Worth a look" and Unusual spending (PAR-9): the web's tabs of those names,
/// pushed here. Unusual spending covers the period Insights shows.
struct WorthALookCard: View {
    let profileCode: String
    let from: CalendarDay
    let to: CalendarDay
    @Environment(InsightFeedModel.self) private var feed
    @Environment(ProfileStore.self) private var profiles: ProfileStore?

    private var canWrite: Bool { profiles?.canWrite ?? false }

    var body: some View {
        Card {
            NavigationLink {
                InsightFeedView(profileCode: profileCode, canDismiss: canWrite, host: .insights)
            } label: {
                row(title: "Worth a look", detail: feed.summary, systemImage: "lightbulb")
            }
            .buttonStyle(.plain)
            Divider().overlay(Palette.border)
            NavigationLink {
                AnomaliesView(profileCode: profileCode, from: from, to: to, canMarkFine: canWrite)
            } label: {
                row(title: "Unusual spending", detail: "Charges far above your usual, \(LedgerDates.rangeLabel(from: from, to: to))",
                    systemImage: "exclamationmark.magnifyingglass")
            }
            .buttonStyle(.plain)
        }
        .task { await feed.loadIfNeeded(profileCode: profileCode) }
    }

    private func row(title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(Palette.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.subtle)
        }
        .frame(minHeight: Metrics.tapMin)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

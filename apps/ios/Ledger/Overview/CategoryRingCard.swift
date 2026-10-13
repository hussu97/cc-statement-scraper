import Charts
import LedgerKit
import SwiftUI

/// Overview's "Where it went": the month's top categories as a ring and a legend. A legend row
/// or a slice opens that category's drill-down for the month on screen (PAR-5).
struct CategoryRingCard: View {
    let overview: Overview
    let profileCode: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var opened: CategoryDrillDownRequest?

    private var categories: [Overview.TopCategory] { overview.ringCategories }

    var body: some View {
        Card {
            SectionHeader(title: "Where it went", trailing: overview.scopeLabel())
            if categories.isEmpty {
                Text(overview.emptyCategoriesMessage()).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            } else if typeSize.prefersStackedRows {
                VStack(alignment: .leading, spacing: 16) {
                    ring.frame(maxWidth: .infinity)
                    legend
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    ring
                    legend
                }
            }
        }
        .navigationDestination(item: $opened) { request in
            CategoryDetailView(request: request, profileCode: profileCode)
        }
    }

    private var ring: some View {
        Chart(categories) { category in
            SectorMark(angle: .value("Amount", category.amount.chartValue),
                       innerRadius: .ratio(0.62), angularInset: 1.5)
                .foregroundStyle(ChartPalette.color(for: category.colorToken))
        }
        .chartOverlay { _ in
            // A tap on a slice opens it (Swift Charts' angle selection wants a drag inside a scroll view).
            GeometryReader { geo in
                Circle().fill(.clear).contentShape(Circle())
                    .onTapGesture { location in
                        let fraction = Overview.ringFraction(dx: location.x - geo.size.width / 2,
                                                             dy: location.y - geo.size.height / 2)
                        guard let category = Overview.ringCategory(categories, atFraction: fraction) else { return }
                        opened = overview.drillDown(category)
                    }
            }
        }
        .frame(width: 128, height: 128)
        .chartBackground { _ in
            VStack(spacing: 0) {
                Text(MoneyFormat.compact(overview.spend)).font(Typography.amountLarge).moneyLine()
                Text("AED").font(Typography.caption).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 22)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .chartAccessibility(.categoryRing(categories, total: overview.spend))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(categories) { category in
                Button { opened = overview.drillDown(category) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CategoryDot(token: category.colorToken)
                        Text(category.displayName).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                            .lineLimit(typeSize.prefersStackedRows ? 2 : 1)
                        Spacer(minLength: 4)
                        Text(MoneyFormat.compact(category.amount)).font(Typography.rowMeta).moneyLine()
                            .foregroundStyle(Palette.muted)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.subtle)
                    }
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(category.displayName)")
            }
        }
    }
}

import LedgerKit
import SwiftUI

/// Trends' table: every bucket with spend, newest first, with the server's total and count.
/// Ungrouped, a row opens its transactions in Activity; grouped, it opens to each group's
/// slice, and a slice opens its own transactions where Activity can show them.
struct TrendsTable: View {
    let series: TrendsSeries
    @Bindable var model: TrendsModel
    @Environment(TabRouter.self) private var tabs: TabRouter?

    var body: some View {
        Card {
            SectionHeader(title: series.grain.tableTitle)
            ForEach(series.spentBuckets) { bucket in
                VStack(alignment: .leading, spacing: 8) {
                    if series.isGrouped {
                        Button { model.toggleBucket(bucket.id) } label: {
                            BucketRow(bucket: bucket, glyph: model.selectedBucket == bucket.id ? "chevron.up" : "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(model.selectedBucket == bucket.id ? "Hides its split" : "Shows its split")
                        if model.selectedBucket == bucket.id { slices(bucket) }
                    } else if let tabs, let query = series.activityQuery(bucket: bucket, group: nil) {
                        Button { tabs.openActivity(query) } label: { BucketRow(bucket: bucket, glyph: "chevron.right") }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows its transactions in Activity")
                    } else {
                        BucketRow(bucket: bucket, glyph: nil)
                    }
                }
                if bucket.id != series.spentBuckets.last?.id { Divider().overlay(Palette.border) }
            }
        }
    }

    /// The bucket's groups, each a link when Activity can show it, then the whole bucket.
    @ViewBuilder private func slices(_ bucket: TrendsSeries.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bucket.entries) { entry in
                if let group = series.group(key: entry.groupKey) {
                    if let tabs, let query = series.activityQuery(bucket: bucket, group: group) {
                        Button { tabs.openActivity(query) } label: { SliceRow(group: group, entry: entry, linked: true) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows its transactions in Activity")
                    } else {
                        SliceRow(group: group, entry: entry, linked: false)
                    }
                }
            }
            if let tabs, let query = series.activityQuery(bucket: bucket, group: nil) {
                Button { tabs.openActivity(query) } label: {
                    Label("See all transactions", systemImage: "list.bullet")
                        .font(Typography.caption)
                        .frame(minHeight: Metrics.tapMin)
                }
                .buttonStyle(.borderless)
                .tint(Palette.accent)
            }
        }
        .padding(.leading, 12)
    }
}

private struct BucketRow: View {
    let bucket: TrendsSeries.Bucket
    let glyph: String?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                if let count = bucket.txnCount {
                    Text(TrendsSeries.countLabel(count)).font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 8)
            if let total = bucket.total {
                Text(MoneyFormat.aed(total, fractionDigits: 0)).font(Typography.amount).moneyLine()
            }
            if let glyph {
                Image(systemName: glyph).font(.caption).foregroundStyle(Palette.subtle)
            }
        }
        .frame(minHeight: Metrics.tapMin)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SliceRow: View {
    let group: TrendsSeries.Group
    let entry: TrendsSeries.Entry
    let linked: Bool

    var body: some View {
        HStack(spacing: 8) {
            TrendDot(token: group.colorToken)
            Text(group.label).font(Typography.rowMeta).foregroundStyle(Palette.ink2).lineLimit(1)
            Spacer(minLength: 6)
            if let count = entry.txnCount {
                Text("\(count)×").font(Typography.caption).monospacedDigit().foregroundStyle(Palette.muted)
            }
            Text(MoneyFormat.aed(entry.amount, fractionDigits: 0)).font(Typography.rowMeta).moneyLine()
            if linked {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.subtle)
            }
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

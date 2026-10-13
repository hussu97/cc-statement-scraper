import LedgerKit
import SwiftUI
import WidgetKit

/// "Month spend": this month's spend and the server's pace against the
/// same day last month (`SpendWidgetContent`).
struct SpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LedgerWidgetKind.spend, provider: SnapshotProvider()) { entry in
            SpendWidgetView(entry: entry)
        }
        .configurationDisplayName("Month spend")
        .description("This month's card spend so far and how it compares with last month.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct SpendWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var content: SpendWidgetContent {
        SpendWidgetContent.make(snapshot: entry.snapshot, placement: family.placement,
                                requireAuth: entry.requireAuth, now: entry.date)
    }

    var body: some View {
        let c = content
        switch family {
        case .accessoryInline:
            Text(c.inline).containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(c.monthName) spend").font(.caption.weight(.semibold)).widgetAccentable()
                if let message = c.message {
                    Text(message).font(.caption2).lineLimit(2)
                } else {
                    // No privacySensitive here: whether the Lock Screen shows money is
                    // WidgetPrivacy's decision (Require Face ID), not a redaction.
                    Text(c.amount ?? WidgetPrivacy.hiddenAmount).font(.headline).monospacedDigit()
                    if let pace = c.paceShort { Text(pace).font(.caption2).lineLimit(1) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(c.accessibilityLabel)
            .containerBackground(for: .widget) { Color.clear }
        default:
            WidgetCard {
                if let message = c.message {
                    WidgetMessage(title: "\(c.monthName) spend", text: message)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(c.monthName) so far")
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent).lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("AED").font(.caption).foregroundStyle(Palette.muted)
                            Text(c.heroNumber ?? WidgetPrivacy.hiddenAmount)
                                .font(.system(family == .systemSmall ? .title : .largeTitle, design: .serif))
                                .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                                .foregroundStyle(Palette.ink)
                                .privacySensitive()
                        }
                        if let pace = family == .systemSmall ? c.paceShort : c.pace {
                            Text(pace).font(.caption).foregroundStyle(c.paceTone.color).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if let footnote = family == .systemSmall ? c.footnoteShort : c.footnote {
                            Text(footnote).font(.caption2).foregroundStyle(Palette.subtle).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(c.accessibilityLabel)
                }
            }
        }
    }
}

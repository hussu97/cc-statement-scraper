import LedgerKit
import SwiftUI
import WidgetKit

/// "Next due": the soonest upcoming statement due date, with its balance and
/// minimum on the Home Screen (`DueWidgetContent`).
struct DueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LedgerWidgetKind.due, provider: SnapshotProvider()) { entry in
            DueWidgetView(entry: entry)
        }
        .configurationDisplayName("Next due")
        .description("The next card statement to pay, from your latest statements.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

struct DueWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let c = DueWidgetContent.make(snapshot: entry.snapshot, placement: family.placement,
                                      requireAuth: entry.requireAuth, now: entry.date)
        switch family {
        case .accessoryInline:
            Text(c.inline).containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(c.card ?? "Next due").font(.caption.weight(.semibold)).lineLimit(1).widgetAccentable()
                if let message = c.message {
                    Text(message).font(.caption2).lineLimit(2)
                } else {
                    Text(c.when ?? "").font(.headline).lineLimit(1)
                    Text([c.date, c.amount].compactMap { $0 }.joined(separator: " · ")).font(.caption2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(c.accessibilityLabel)
            .containerBackground(for: .widget) { Color.clear }
        default:
            WidgetCard {
                if let message = c.message {
                    WidgetMessage(title: "Next due", text: message)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Next due").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                        Text(c.card ?? "").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            .lineLimit(2)
                        Text(c.when ?? "").font(.caption.weight(.semibold)).foregroundStyle(c.whenTone.color)
                        if let date = c.date { Text(date).font(.caption).foregroundStyle(Palette.muted) }
                        Spacer(minLength: 0)
                        if let amount = c.amount {
                            Text(amount).font(.system(.callout, design: .serif)).monospacedDigit()
                                .foregroundStyle(Palette.ink).minimumScaleFactor(0.6).lineLimit(1)
                                .privacySensitive()
                        }
                        if let minimum = c.minimum {
                            Text(minimum).font(.caption2).foregroundStyle(Palette.muted).privacySensitive()
                        }
                        if let others = c.others {
                            Text(others).font(.caption2).foregroundStyle(Palette.subtle).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(c.accessibilityLabel)
                }
            }
        }
    }
}

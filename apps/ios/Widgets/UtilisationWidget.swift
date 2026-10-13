import LedgerKit
import SwiftUI
import WidgetKit

/// "Utilisation": each card's latest statement balance against its limit, as
/// the server worked it out (`UtilisationWidgetContent`). A percent, not an
/// amount, so it shows on the Lock Screen too.
struct UtilisationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LedgerWidgetKind.utilisation, provider: SnapshotProvider()) { entry in
            UtilisationWidgetView(entry: entry)
        }
        .configurationDisplayName("Utilisation")
        .description("How much of each card's limit its latest statement used.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct UtilisationWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let c = UtilisationWidgetContent.make(snapshot: entry.snapshot)
        switch family {
        case .accessoryCircular:
            Group {
                if let top = c.rows.first {
                    Gauge(value: top.fraction) {
                        Text("Used")
                    } currentValueLabel: {
                        Text(top.percent).monospacedDigit()
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .accessibilityLabel("\(top.title), \(top.percent) of the limit used")
                } else {
                    Image(systemName: "creditcard").accessibilityLabel(c.inline)
                }
            }
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Utilisation").font(.caption.weight(.semibold)).widgetAccentable()
                if let message = c.message {
                    Text(message).font(.caption2).lineLimit(2)
                } else {
                    ForEach(c.rows.prefix(2)) { row in
                        HStack {
                            Text(row.title).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(row.percent).monospacedDigit()
                        }
                        .font(.caption2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }
        default:
            WidgetCard {
                if let message = c.message {
                    WidgetMessage(title: "Utilisation", text: message)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Utilisation").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                        ForEach(c.rows.prefix(family == .systemSmall ? 2 : 3)) { row in
                            UtilisationRow(row: row)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

private struct UtilisationRow: View {
    let row: UtilisationWidgetContent.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.title).font(.caption).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 4)
                Text(row.percent).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(row.tone.color)
            }
            ProgressView(value: row.fraction).tint(row.tone.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.percent) of the limit used")
    }
}

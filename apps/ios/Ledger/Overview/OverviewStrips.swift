import LedgerKit
import SwiftUI

/// Pending card alerts under the hero: `"2 pending · AED 145.00"` and the last SMS.
struct PendingStrip: View {
    let summary: String
    let lastSMS: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                dot
                summaryText
                Spacer()
                if let lastSMS { lastText(lastSMS) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { dot; summaryText }
                if let lastSMS { lastText(lastSMS) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warnSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
    }

    private var dot: some View { Circle().fill(Palette.warn).frame(width: 8, height: 8) }
    private var summaryText: some View {
        Text(summary).font(Typography.rowTitle).monospacedDigit().foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func lastText(_ text: String) -> some View {
        Text(text).font(Typography.caption).foregroundStyle(Palette.muted)
    }
}

/// SMS stuck on this phone for over an hour (`OutboxStatus.staleAlert`); opens Settings.
struct OutboxStrip: View {
    let alert: StaleOutboxAlert
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "tray.full").foregroundStyle(Palette.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Text(alert.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.dangerSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Settings")
    }
}

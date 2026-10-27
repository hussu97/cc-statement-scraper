import LedgerKit
import SwiftUI

/// A live note's stocks, one bar each: symbol, last close and start, what it needs, and the bar
/// with the call level (tall tick), the barrier or break-even (short tick) and today's close (dot).
/// The positions and words are LedgerKit's (`NoteStockBar`).
struct NoteStockBars: View {
    let bars: [NoteStockBar]
    var showsLegend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(bars) { NoteStockBarRow(bar: $0) }
            if showsLegend {
                Text(NoteStockBar.legend).font(Typography.caption).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct NoteStockBarRow: View {
    let bar: NoteStockBar

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bar.symbol).font(Typography.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                Text("\(bar.closeText) · \(bar.startText)").font(Typography.caption).foregroundStyle(Palette.muted)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(bar.statusText).font(Typography.caption.weight(.medium)).foregroundStyle(bar.statusTone.color)
                    .lineLimit(1)
            }
            BarTrack(bar: bar).frame(height: 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.accessibilityLabel)
    }
}

/// The track with its two ticks and the dot.
private struct BarTrack: View {
    let bar: NoteStockBar

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let mid = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.surface3)
                    .frame(width: w, height: 4)
                    .position(x: w / 2, y: mid)
                if let b = bar.barrierAt {
                    Rectangle().fill(Palette.muted).frame(width: 2, height: 10)
                        .position(x: b * w, y: mid)
                }
                if let c = bar.callAt {
                    Rectangle().fill(Palette.ink2).frame(width: 2, height: 16)
                        .position(x: c * w, y: mid)
                }
                if let d = bar.closeAt {
                    Circle().fill(bar.dotTone.color)
                        .overlay(Circle().stroke(Palette.surface, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(x: d * w, y: mid)
                }
            }
        }
    }
}

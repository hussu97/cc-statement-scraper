import LedgerKit
import SwiftUI

/// One holding on Investments: a metal's photo or the kind's symbol, the name and the server's AED
/// value (with the holding's own currency beside it), the kind's detail line, gain and 24-hour
/// move, when the value is from (or that it is estimated), and a stale warning. Words are
/// LedgerKit's (`Holding` presentation).
struct HoldingRow: View {
    let holding: Holding
    var chevron = true
    @Environment(BankCatalog.self) private var catalog: BankCatalog?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HoldingThumbnail(holding: holding, supabaseURL: catalog?.supabaseURL)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(holding.name).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text(holding.valueText)
                        .font(holding.hasValue ? Typography.amount : Typography.rowMeta)
                        .foregroundStyle(holding.hasValue ? Palette.ink : Palette.muted).moneyLine()
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(holding.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                    Spacer(minLength: 8)
                    if let own = holding.ownValueText {
                        Text(own).font(Typography.caption).foregroundStyle(Palette.muted).moneyLine()
                    }
                }
                // Gain and the day's move side by side, stacked when they don't fit.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { gain; Spacer(minLength: 8); change }
                    VStack(alignment: .leading, spacing: 2) { gain; change }
                }
                if holding.asOfText() != nil || holding.incomeText != nil {
                    HStack(spacing: 6) {
                        if let asOf = holding.asOfText() {
                            Text(asOf).font(Typography.caption).foregroundStyle(Palette.muted)
                        }
                        if let income = holding.incomeText {
                            Text(income).font(Typography.caption).foregroundStyle(Palette.positive).moneyLine()
                        }
                    }
                }
                if let stale = holding.staleText() {
                    Label(stale, systemImage: "clock.badge.exclamationmark")
                        .font(Typography.caption).foregroundStyle(Palette.warn)
                }
            }
            if chevron {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted).padding(.top, 4)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(holding.accessibilityLabel)
    }

    private var gain: some View {
        Text(holding.gainText ?? holding.noGainText).font(Typography.caption).fixedSize()
            .foregroundStyle(holding.gainText == nil ? Palette.muted : holding.gainTone.color)
    }

    @ViewBuilder private var change: some View {
        if let change = holding.changeText {
            Text(change).font(Typography.caption).foregroundStyle(holding.changeTone.color).fixedSize()
        }
    }
}

/// A metal's photo, or a tile with the kind's symbol for the other kinds.
struct HoldingThumbnail: View {
    let holding: Holding
    let supabaseURL: URL?
    var side: CGFloat = 44

    var body: some View {
        if holding.hasPhoto {
            HoldingPhoto(holding: holding, supabaseURL: supabaseURL, side: side)
        } else {
            RoundedRectangle(cornerRadius: Metrics.radiusMd).fill(Palette.accentSoft)
                .frame(width: side, height: side)
                .overlay {
                    Image(systemName: holding.kind.systemImage)
                        .font(.system(size: side * 0.42, weight: .medium))
                        .foregroundStyle(Palette.accent)
                }
                .accessibilityElement()
                .accessibilityLabel(holding.imageLabel)
                .accessibilityAddTraits(.isImage)
        }
    }
}

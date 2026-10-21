import LedgerKit
import SwiftUI

/// Wealth's Investments tab (gold and silver for now): the total the server values them at, the
/// gain against what was paid and the last 24 hours, today's Dubai retail prices, 90 days of value
/// or price, and the holdings, each opening its edit sheet for owners. Every figure is the server's.
struct InvestmentsView: View {
    let model: InvestmentsModel
    let profileCode: String
    let canEdit: Bool
    @State private var editing: HoldingDraft?
    @Environment(BankCatalog.self) private var catalog: BankCatalog?

    var body: some View {
        Page {
            if let notice = model.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(Typography.rowMeta)
                    .foregroundStyle(notice.isError ? Palette.danger : Palette.positive)
                    .padding(.top, 8)
            }
            StateContainer(state: model.state, retry: reload) { content in
                InvestmentsHero(valuation: content.valuation)
                PriceStrip(valuation: content.valuation)
                if !content.valuation.isEmpty {
                    InvestmentsChartCard(model: model, content: content)
                }
                holdings(content.valuation)
            }
            .padding(.top, 8)
        }
        .rootNavigation("Investments")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = model.newDraft() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add holding")
                }
            }
        }
        .sheet(item: $editing) { draft in
            HoldingSheet(model: model, draft: draft, original: original(of: draft), profileCode: profileCode,
                         canEdit: canEdit)
        }
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode) }
        .onDisappear { model.notice = nil }
    }

    private func holdings(_ valuation: HoldingsValuation) -> some View {
        Card {
            SectionHeader(title: "Holdings", trailing: valuation.isEmpty ? nil : valuation.countText)
            if valuation.isEmpty {
                Text(HoldingsValuation.emptyMessage(canEdit: canEdit))
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                if canEdit {
                    Button("Add holding") { editing = model.newDraft() }
                        .buttonStyle(.bordered).tint(Palette.accent)
                }
            }
            ForEach(valuation.holdings) { holding in
                if holding.id != valuation.holdings.first?.id { Divider().overlay(Palette.border) }
                if canEdit {
                    Button { editing = model.draft(for: holding) } label: { row(holding, chevron: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the holding to edit or close it")
                } else {
                    row(holding, chevron: false)
                }
            }
        }
    }

    private func row(_ holding: Holding, chevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HoldingPhoto(holding: holding, supabaseURL: catalog?.supabaseURL)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(holding.name).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text(holding.valueText)
                        .font(holding.hasValue ? Typography.amount : Typography.rowMeta)
                        .foregroundStyle(holding.hasValue ? Palette.ink : Palette.muted).moneyLine()
                }
                Text(holding.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                // Gain and the day's move side by side, stacked when they don't fit.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { gain(holding); Spacer(minLength: 8); change(holding) }
                    VStack(alignment: .leading, spacing: 2) { gain(holding); change(holding) }
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

    private func gain(_ holding: Holding) -> some View {
        Text(holding.gainText ?? holding.noGainText).font(Typography.caption).fixedSize()
            .foregroundStyle(holding.gainText == nil ? Palette.muted : holding.gainTone.color)
    }

    @ViewBuilder private func change(_ holding: Holding) -> some View {
        if let change = holding.changeText {
            Text(change).font(Typography.caption).foregroundStyle(holding.changeTone.color).fixedSize()
        }
    }

    private func original(of draft: HoldingDraft) -> Holding? {
        model.state.value?.valuation.holdings.first { $0.holdingCode == draft.holdingCode }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

/// The total, the gain against cost and the last 24 hours, and what the figures leave out.
private struct InvestmentsHero: View {
    let valuation: HoldingsValuation
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = Typography.heroBaseSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("GOLD AND SILVER").font(Typography.caption).tracking(1.2).foregroundStyle(Palette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("AED").font(Typography.heroUnit).foregroundStyle(Palette.muted)
                    Text(valuation.heroAmount).font(Typography.hero(size: heroSize)).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(valuation.heroAccessibilityLabel)
            VStack(alignment: .leading, spacing: 4) {
                if let cost = valuation.costAed { line("Paid", MoneyFormat.aed(cost), Palette.ink) }
                line("Gain", valuation.gainText ?? "Add what you paid", valuation.gainText == nil ? Palette.muted
                                                                                                : valuation.gainTone.color)
                if let change = valuation.changeText { line("Last 24 hours", change, valuation.changeTone.color) }
            }
            ForEach(valuation.caveats, id: \.self) { caveat in
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(Typography.caption).foregroundStyle(Palette.warn)
            }
        }
    }

    private func line(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            Spacer()
            Text(value).font(Typography.amount).foregroundStyle(color).moneyLine()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Today's Dubai retail prices per gram (24K, 22K, 21K, 18K, silver) with the 24-hour move.
private struct PriceStrip: View {
    let valuation: HoldingsValuation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(valuation.retailPrices, id: \.quote) { item in tile(item.quote, item.price) }
                }
            }
            Text(valuation.pricesNote()).font(Typography.caption).foregroundStyle(Palette.muted)
        }
    }

    private func tile(_ quote: MetalQuote, _ price: MetalPrice) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(quote.label).font(Typography.caption).foregroundStyle(Palette.muted)
                if price.isStale { Chip(label: "Stale", tone: .warn) }
            }
            Text(price.priceText).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
            Text(price.changeText ?? "–").font(Typography.caption)
                .foregroundStyle(price.changeText == nil ? Palette.muted : price.changeTone.color)
        }
        .padding(10)
        .frame(minWidth: 104, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMd).stroke(Palette.border, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(quote.label), \(price.priceText) per gram" + (price.changeText.map { ", \($0) in 24 hours" } ?? "")
                            + (price.isStale ? ", stale" : ""))
    }
}

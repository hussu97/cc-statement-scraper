import LedgerKit
import SwiftUI

/// Wealth's Investments tab: the total the server values every holding at, the gain against what
/// went in and the last 24 hours, today's Dubai retail metal prices (while there is gold or silver),
/// 90 days of value or price, returns by period, and the holdings grouped by kind, each opening its
/// own screen (a structured note its note screen), then the structured notes, live and ended.
/// Owners add a holding of any kind, or a note from its term sheet. Every figure is the server's.
struct InvestmentsView: View {
    let model: InvestmentsModel
    let notes: NotesModel
    let profileCode: String
    let canEdit: Bool
    @State private var editing: HoldingDraft?
    @State private var addingNote: AddNoteModel?
    /// A note just added: its screen opens.
    @State private var openedNote: String?

    var body: some View {
        Page {
            if let notice = model.notice ?? notes.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(Typography.rowMeta)
                    .foregroundStyle(notice.isError ? Palette.danger : Palette.positive)
                    .padding(.top, 8)
            }
            StateContainer(state: model.state, retry: reload) { content in
                InvestmentsHero(valuation: content.valuation)
                if content.valuation.showsMetalPrices { PriceStrip(valuation: content.valuation) }
                if !content.valuation.isEmpty {
                    InvestmentsChartCard(model: model, content: content)
                    ReturnsCard(model: model, profileCode: profileCode)
                }
                holdings(content.valuation)
            }
            .padding(.top, 8)
            NotesCard(model: notes, profileCode: profileCode, canEdit: canEdit) { addingNote = notes.addModel() }
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
            HoldingSheet(model: model, draft: draft, profileCode: profileCode, canEdit: canEdit)
        }
        .sheet(item: $addingNote) { add in
            AddNoteSheet(model: add, profileCode: profileCode, canEdit: canEdit) { openedNote = $0 }
        }
        .navigationDestination(item: $openedNote) { code in
            NoteDetailView(notes: notes, holdingCode: code, profileCode: profileCode, canEdit: canEdit)
        }
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .task { await notes.loadIfNeeded(profileCode: profileCode) }
        .refreshable {
            async let a: Void = model.load(profileCode: profileCode)
            async let b: Void = notes.load(profileCode: profileCode)
            _ = await (a, b)
        }
        .onDisappear {
            model.notice = nil
            notes.notice = nil
        }
    }

    @ViewBuilder private func holdings(_ valuation: HoldingsValuation) -> some View {
        if valuation.groups.isEmpty {
            Card {
                SectionHeader(title: "Holdings")
                Text(HoldingsValuation.emptyMessage(canEdit: canEdit, onlyNotes: valuation.onlyNotes))
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                if canEdit {
                    Button("Add holding") { editing = model.newDraft() }
                        .buttonStyle(.bordered).tint(Palette.accent)
                }
            }
        }
        ForEach(valuation.groups) { group in
            Card {
                SectionHeader(title: group.title, trailing: group.countText)
                ForEach(group.holdings) { holding in
                    if holding.id != group.holdings.first?.id { Divider().overlay(Palette.border) }
                    NavigationLink {
                        if holding.kind == .structuredNote {
                            NoteDetailView(notes: notes, holdingCode: holding.holdingCode, profileCode: profileCode,
                                           canEdit: canEdit)
                        } else {
                            HoldingDetailView(investments: model, holdingCode: holding.holdingCode,
                                              profileCode: profileCode, canEdit: canEdit)
                        }
                    } label: {
                        HoldingRow(holding: holding)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the holding's money in and out, values and returns")
                }
            }
        }
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
                Text("ALL HOLDINGS").font(Typography.caption).tracking(1.2).foregroundStyle(Palette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("AED").font(Typography.heroUnit).foregroundStyle(Palette.muted)
                    Text(valuation.heroAmount).font(Typography.hero(size: heroSize)).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(valuation.heroAccessibilityLabel)
            VStack(alignment: .leading, spacing: 4) {
                if let cost = valuation.costAed { line("Put in", MoneyFormat.aed(cost), Palette.ink) }
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
